// Fuzz harness for the wasm module loader.
//
// Reads wasm bytes from stdin and attempts to decode, instantiate,
// and invoke exported functions. Any error is expected (invalid wasm);
// a panic/crash is a real bug.
//
// Usage:
//   echo -n '<bytes>' | ./zig-out/bin/fuzz_loader
//   head -c 100 /dev/urandom | wasm-tools smith | ./zig-out/bin/fuzz_loader
//   AFL: afl-fuzz -i corpus/ -o findings/ -- ./zig-out/bin/fuzz_loader

const std = @import("std");
const zwasm = @import("zwasm");

const FUEL_LIMIT: u64 = 1_000_000;

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.fs.File.stdin();
    var read_buf: [4096]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    const input = reader.interface.allocRemaining(allocator, .unlimited) catch return;
    defer allocator.free(input);

    fuzzOne(allocator, input);
}

fn fuzzOne(allocator: std.mem.Allocator, input: []const u8) void {
    // Load with fuel limit to prevent infinite loops in start functions
    const module = zwasm.WasmModule.loadWithFuel(allocator, input, FUEL_LIMIT) catch return;
    defer module.deinit();

    // Invoke zero-arg exported functions to exercise the interpreter
    for (module.export_fns) |ei| {
        if (ei.param_types.len == 0 and ei.result_types.len <= 1) {
            var results: [1]u64 = .{0};
            const result_slice = results[0..ei.result_types.len];
            module.invoke(ei.name, &.{}, result_slice) catch continue;
            // Reset fuel for next function
            module.vm.fuel = FUEL_LIMIT;
        }
    }
}
