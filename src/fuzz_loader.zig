// Fuzz harness for the wasm module loader.
//
// Reads wasm bytes from stdin and attempts to decode + instantiate.
// Any error is expected (invalid wasm); a panic/crash is a real bug.
//
// Usage:
//   echo -n '<bytes>' | ./zig-out/bin/fuzz_loader
//   head -c 100 /dev/urandom | wasm-tools smith | ./zig-out/bin/fuzz_loader
//   AFL: afl-fuzz -i corpus/ -o findings/ -- ./zig-out/bin/fuzz_loader

const std = @import("std");
const zwasm = @import("zwasm");

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
    // Decode + instantiate the module. This exercises:
    // - Binary parser (sections, LEB128, type/function/code/data)
    // - Predecoder (instruction validation, register IR translation)
    // - Store/instance creation (imports, tables, memories, globals)
    // Errors are expected for invalid wasm — only panics/crashes are bugs.
    const module = zwasm.WasmModule.load(allocator, input) catch return;
    module.deinit();
}
