// Example: Inspect a Wasm module's exports.
//
// Build: zig build (from repo root)
// Run:   zig-out/bin/example_inspect

const std = @import("std");
const zwasm = @import("zwasm");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const wasm_bytes = try readFile(allocator, "src/testdata/01_add.wasm");
    defer allocator.free(wasm_bytes);

    var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
    defer module.deinit();

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;

    // List all exported functions with their signatures
    for (module.export_fns) |info| {
        try stdout.print("export: {s}(", .{info.name});
        for (info.param_types, 0..) |p, i| {
            if (i > 0) try stdout.print(", ", .{});
            try stdout.print("{s}", .{@tagName(p)});
        }
        try stdout.print(") -> (", .{});
        for (info.result_types, 0..) |r, i| {
            if (i > 0) try stdout.print(", ", .{});
            try stdout.print("{s}", .{@tagName(r)});
        }
        try stdout.print(")\n", .{});
    }
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
