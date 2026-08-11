//! Custom test runner that LISTS discovered test names instead of running
//! them — the compiler-truth side of `scripts/check_test_discovery.sh`
//! (sweep S5(c)): a named `test "…"` block that exists in source but does
//! not appear in this listing is dead (never executed by any test step),
//! the D-444/ADR-0207 II-2a incident class.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    for (builtin.test_functions) |t| {
        try w.interface.print("{s}\n", .{t.name});
    }
    try w.interface.flush();
}
