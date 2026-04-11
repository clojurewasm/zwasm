//! Fuzz harness for the WAT parser + module loader.
//!
//! Reads WAT text from stdin, converts to wasm, loads, and invokes
//! exported functions. Any error is expected (invalid WAT/wasm);
//! a panic/crash is a real bug.
//!
//! Features:
//! - WASI fallback: tries non-WASI first, then WASI with sandbox caps
//! - Parameterized invoke: synthesizes args from input bytes (up to 8 params)
//! - Multi-value returns: handles up to 8 result values
//! - JIT trigger: calls each function 4 times (HOT_THRESHOLD+1)
//!
//! Usage:
//!   echo '(module)' | ./zig-out/bin/fuzz_wat_loader
//!   cat file.wat | ./zig-out/bin/fuzz_wat_loader

const std = @import("std");
const zwasm = @import("zwasm");

const FUEL_LIMIT: u64 = 1_000_000;
const JIT_CALLS: u32 = 4; // HOT_THRESHOLD(3) + 1
const MAX_ARGS: usize = 8;
const MAX_RESULTS: usize = 8;

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

    // Use WAT source bytes as deterministic arg source
    var arg_pos: usize = 0;

    for (module.export_fns) |ei| {
        const nparams = ei.param_types.len;
        const nresults = ei.result_types.len;
        if (nparams > MAX_ARGS or nresults > MAX_RESULTS) continue;

        // Synthesize args from input bytes
        var args: [MAX_ARGS]u64 = .{0} ** MAX_ARGS;
        for (0..nparams) |i| {
            if (arg_pos + 8 <= wat_source.len) {
                args[i] = std.mem.readInt(u64, wat_source[arg_pos..][0..8], .little);
                arg_pos += 8;
            }
        }
        const arg_slice = args[0..nparams];

        var results: [MAX_RESULTS]u64 = .{0} ** MAX_RESULTS;
        const result_slice = results[0..nresults];

        // Call multiple times to trigger JIT compilation
        for (0..JIT_CALLS) |_| {
            module.vm.fuel = FUEL_LIMIT;
            module.invoke(ei.name, arg_slice, result_slice) catch break;
        }
    }
}
