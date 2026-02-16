// Example: Register host functions callable from Wasm.
//
// The Wasm module imports "env.print_i32" and "env.print_str".
// We provide native Zig callbacks that pop args from the Wasm stack.
//
// Build: zig build (from repo root)
// Run:   zig-out/bin/example_host_functions

const std = @import("std");
const zwasm = @import("zwasm");

fn hostPrintI32(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const val = vm.popOperandI32();

    var buf: [256]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;
    try stderr.print("[host] print_i32({d})\n", .{val});
    try stderr.flush();
}

fn hostPrintStr(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    // print_str(offset: i32, len: i32) — pop in reverse order
    const len = vm.popOperandU32();
    const offset = vm.popOperandU32();
    _ = offset;
    _ = len;
    // Memory read requires module access; just consume the args here.
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const wasm_bytes = try readFile(allocator, "src/testdata/04_imports.wasm");
    defer allocator.free(wasm_bytes);

    const imports = [_]zwasm.ImportEntry{
        .{
            .module = "env",
            .source = .{ .host_fns = &.{
                .{ .name = "print_i32", .callback = hostPrintI32, .context = 0 },
                .{ .name = "print_str", .callback = hostPrintStr, .context = 0 },
            } },
        },
    };

    var module = try zwasm.WasmModule.loadWithImports(allocator, wasm_bytes, &imports);
    defer module.deinit();

    var args = [_]u64{ 7, 3 };
    var results = [_]u64{};
    try module.invoke("compute_and_print", &args, &results);

    var buf: [256]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("compute_and_print(7, 3) completed\n", .{});
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
