// Example: Read and write linear memory.
//
// Build: zig build (from repo root)
// Run:   zig-out/bin/example_memory

const std = @import("std");
const zwasm = @import("zwasm");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const wasm_bytes = try readFile(allocator, "src/testdata/03_memory.wasm");
    defer allocator.free(wasm_bytes);

    var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
    defer module.deinit();

    // Write a string to linear memory
    try module.memoryWrite(0, "Hello, zwasm!");

    // Read it back
    const data = try module.memoryRead(allocator, 0, 13);
    defer allocator.free(data);

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("Memory content: {s}\n", .{data});
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
