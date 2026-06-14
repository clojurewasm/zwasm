// hello.zig — minimal Zig → wasm32-wasi: write a line to stdout via fd_write.
const std = @import("std");
const w = std.os.wasi;

fn writeStr(s: []const u8) void {
    var iov = [_]w.ciovec_t{.{ .base = s.ptr, .len = s.len }};
    var n: usize = undefined;
    _ = w.fd_write(1, &iov, 1, &n);
}

pub fn main() void {
    writeStr("Hello from Zig on WASI!\n");
}
