// Example: Load a Wasm module and call an exported function.
//
// Build: zig build (from repo root)
// Run:   zig-out/bin/example_basic

const std = @import("std");
const zwasm = @import("zwasm");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load a Wasm module from file
    const wasm_bytes = try readFile(allocator, "src/testdata/02_fibonacci.wasm");
    defer allocator.free(wasm_bytes);

    var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
    defer module.deinit();

    // Call the "fib" export with argument 10
    var args = [_]u64{10};
    var results = [_]u64{0};
    try module.invoke("fib", &args, &results);

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("fib(10) = {d}\n", .{results[0]});
    try stdout.flush();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    const n = try file.readAll(data);
    return data[0..n];
}
