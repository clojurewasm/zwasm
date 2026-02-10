// Benchmark: load and call fib(N) using zwasm.
// Usage: zig-out/bin/fib_bench [N]  (default N=35)

const std = @import("std");
const types = @import("zwasm");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse optional argument for N
    var n: u64 = 35;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 1) {
        n = std.fmt.parseInt(u64, args[1], 10) catch 35;
    }

    // Read wasm file from disk
    const wasm_bytes = try readFile(allocator, "src/testdata/02_fibonacci.wasm");
    defer allocator.free(wasm_bytes);

    var module = try types.WasmModule.load(allocator, wasm_bytes);
    defer module.deinit();

    var wasm_args = [_]u64{n};
    var results = [_]u64{0};
    try module.invoke("fib", &wasm_args, &results);

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("fib({d}) = {d}\n", .{ n, results[0] });
    try stdout.flush();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    const read = try file.readAll(data);
    return data[0..read];
}
