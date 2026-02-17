// Fuzz harness for the WAT parser + module loader.
//
// Reads WAT text from stdin, converts to wasm, loads, and invokes
// exported functions. Any error is expected (invalid WAT/wasm);
// a panic/crash is a real bug.
//
// Usage:
//   echo '(module)' | ./zig-out/bin/fuzz_wat_loader
//   cat file.wat | ./zig-out/bin/fuzz_wat_loader

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

fn fuzzOne(allocator: std.mem.Allocator, wat_source: []const u8) void {
    // Load from WAT with fuel limit (exercises parser + encoder + loader)
    const module = zwasm.WasmModule.loadFromWatWithFuel(allocator, wat_source, FUEL_LIMIT) catch return;
    defer module.deinit();

    // Invoke zero-arg exported functions to exercise the interpreter
    for (module.export_fns) |ei| {
        if (ei.param_types.len == 0 and ei.result_types.len <= 1) {
            var results: [1]u64 = .{0};
            const result_slice = results[0..ei.result_types.len];
            module.invoke(ei.name, &.{}, result_slice) catch continue;
            module.vm.fuel = FUEL_LIMIT;
        }
    }
}
