// Example: Run a WASI module.
//
// Build: zig build (from repo root)
// Run:   zig-out/bin/example_wasi

const std = @import("std");
const zwasm = @import("zwasm");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const wasm_bytes = try readFile(allocator, "src/testdata/07_wasi_hello.wasm");
    defer allocator.free(wasm_bytes);

    // Load with WASI support
    var module = try zwasm.WasmModule.loadWasi(allocator, wasm_bytes);
    defer module.deinit();

    // Run _start (the WASI entry point)
    var args = [_]u64{};
    var results = [_]u64{};
    module.invoke("_start", &args, &results) catch {
        // WASI proc_exit triggers a trap — check exit code
        if (module.getWasiExitCode()) |code| {
            if (code != 0) std.process.exit(@truncate(code));
            return;
        }
    };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    const n = try file.readAll(data);
    return data[0..n];
}
