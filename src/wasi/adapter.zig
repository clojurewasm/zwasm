//! WASI **Preview 2 → Preview 1 adapter** name-map (CM campaign chunk D1;
//! WASI-P2 `wasi:cli` / `wasi:io` / `wasi:clocks` / `wasi:random` WIT).
//!
//! A P2 component imports component-level WASI interfaces (`wasi:cli/stdout`,
//! `wasi:io/streams`, …). The Component Model host wires those imports to this
//! adapter, which maps each (interface, func) onto the EXISTING Preview 1
//! implementation (`wasi/preview1.zig` + `wasi/fd.zig`) — reusing the P1 impl
//! wholesale per the survey (`component_model_survey`). This file is the pure
//! NAME-MAP + classifier (D1-1); the resource-stream → fd bridge + the host
//! wiring land in D1-2+. Gated `-Dwasi=preview2`.
//!
//! No-copy: v1 `component.zig` `WasiAdapter`/`p2_to_p1_map` is a flat
//! interface→p1-module table; re-derived here as a typed `(interface, func) →
//! P2Op → P1Target` classifier so the integration dispatches without string
//! re-parsing.

const std = @import("std");

/// The CLI-subset P2 operations the adapter recognises. The richer P2 surface
/// (full filesystem / poll / sockets) extends this in later chunks.
pub const P2Op = enum {
    // wasi:cli/{stdout,stderr,stdin} — acquire the std stream resources.
    cli_get_stdout,
    cli_get_stderr,
    cli_get_stdin,
    // wasi:io/streams — output-stream methods.
    out_stream_write,
    out_stream_blocking_write_and_flush,
    out_stream_blocking_flush,
    out_stream_drop,
    // wasi:io/streams — input-stream methods.
    in_stream_read,
    in_stream_blocking_read,
    in_stream_drop,
    // wasi:cli/exit.
    cli_exit,
    // wasi:clocks.
    clocks_wall_now,
    clocks_monotonic_now,
    // wasi:random.
    random_get_bytes,
    // wasi:filesystem/types — `descriptor` resource methods. A descriptor is a
    // P1 fd; these forward to the seekable-fd P1 ops (the stream-via methods
    // that MINT new stream resources land in a later chunk).
    fs_descriptor_read,
    fs_descriptor_write,
    fs_descriptor_open_at,
    fs_descriptor_sync,
    fs_descriptor_stat,
    fs_descriptor_get_type,
    fs_descriptor_drop,
    // wasi:filesystem/preopens.
    fs_get_directories,
};

/// What P1 facility a `P2Op` ultimately drives (so the D1-2 integration maps
/// without re-parsing names).
pub const P1Target = union(enum) {
    /// Acquire/operate the std stream resource for this fd (1=stdout, 2=stderr,
    /// 0=stdin). `get-*` mint a handle; stream methods forward to fd ops.
    std_stream: u32,
    /// Forward a stream write to P1 `fd_write` on the bound fd.
    fd_write: u32,
    /// Forward a stream read to P1 `fd_read` on the bound fd.
    fd_read: u32,
    /// No P1 syscall (handle bookkeeping only — flush/drop on a std stream).
    noop,
    /// P1 `proc_exit`.
    proc_exit,
    /// P1 `clock_time_get` for the given clock id (0=realtime, 1=monotonic).
    clock_time_get: u32,
    /// P1 `random_get`.
    random_get,
    /// `descriptor` (P1 fd) ops — the fd is resolved from the handle rep at
    /// call time, so these carry no fixed fd.
    fd_pread,
    fd_pwrite,
    /// P1 `path_open` relative to a directory descriptor.
    path_open,
    fd_sync,
    fd_filestat_get,
    fd_fdstat_get,
    fd_close,
    /// P1 preopens enumeration (`fd_prestat_get` / `fd_prestat_dir_name`).
    preopens_get_directories,
};

pub fn p1Target(op: P2Op) P1Target {
    return switch (op) {
        .cli_get_stdout => .{ .std_stream = 1 },
        .cli_get_stderr => .{ .std_stream = 2 },
        .cli_get_stdin => .{ .std_stream = 0 },
        .out_stream_write, .out_stream_blocking_write_and_flush => .{ .fd_write = 1 }, // fd resolved from the handle at call time
        .out_stream_blocking_flush, .out_stream_drop, .in_stream_drop => .noop,
        .in_stream_read, .in_stream_blocking_read => .{ .fd_read = 0 },
        .cli_exit => .proc_exit,
        .clocks_wall_now => .{ .clock_time_get = 0 },
        .clocks_monotonic_now => .{ .clock_time_get = 1 },
        .random_get_bytes => .random_get,
        .fs_descriptor_read => .fd_pread,
        .fs_descriptor_write => .fd_pwrite,
        .fs_descriptor_open_at => .path_open,
        .fs_descriptor_sync => .fd_sync,
        .fs_descriptor_stat => .fd_filestat_get,
        .fs_descriptor_get_type => .fd_fdstat_get,
        .fs_descriptor_drop => .fd_close,
        .fs_get_directories => .preopens_get_directories,
    };
}

/// True if `interface` (e.g. `"wasi:cli/stdout"`, possibly with an `@version`
/// already stripped by the importname decoder) is a WASI P2 interface the
/// adapter handles.
pub fn isWasiP2Interface(interface: []const u8) bool {
    return std.mem.startsWith(u8, interface, "wasi:");
}

const Entry = struct { iface: []const u8, func: []const u8, op: P2Op };

/// The P2 (interface, func) → `P2Op` table (CLI subset). Method names follow
/// the WIT canonical encoding `[method]output-stream.write` etc.; we match the
/// trailing `.<method>` for resource methods and the bare func for free funcs.
const table = [_]Entry{
    .{ .iface = "wasi:cli/stdout", .func = "get-stdout", .op = .cli_get_stdout },
    .{ .iface = "wasi:cli/stderr", .func = "get-stderr", .op = .cli_get_stderr },
    .{ .iface = "wasi:cli/stdin", .func = "get-stdin", .op = .cli_get_stdin },
    .{ .iface = "wasi:cli/exit", .func = "exit", .op = .cli_exit },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.write", .op = .out_stream_write },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.blocking-write-and-flush", .op = .out_stream_blocking_write_and_flush },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.blocking-flush", .op = .out_stream_blocking_flush },
    .{ .iface = "wasi:io/streams", .func = "[resource-drop]output-stream", .op = .out_stream_drop },
    .{ .iface = "wasi:io/streams", .func = "[method]input-stream.read", .op = .in_stream_read },
    .{ .iface = "wasi:io/streams", .func = "[method]input-stream.blocking-read", .op = .in_stream_blocking_read },
    .{ .iface = "wasi:io/streams", .func = "[resource-drop]input-stream", .op = .in_stream_drop },
    .{ .iface = "wasi:clocks/wall-clock", .func = "now", .op = .clocks_wall_now },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "now", .op = .clocks_monotonic_now },
    .{ .iface = "wasi:random/random", .func = "get-random-bytes", .op = .random_get_bytes },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.read", .op = .fs_descriptor_read },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.write", .op = .fs_descriptor_write },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.open-at", .op = .fs_descriptor_open_at },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.sync", .op = .fs_descriptor_sync },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.stat", .op = .fs_descriptor_stat },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.get-type", .op = .fs_descriptor_get_type },
    .{ .iface = "wasi:filesystem/types", .func = "[resource-drop]descriptor", .op = .fs_descriptor_drop },
    .{ .iface = "wasi:filesystem/preopens", .func = "get-directories", .op = .fs_get_directories },
};

/// Classify a P2 import `(interface, func)` → the `P2Op` it maps to, or null if
/// the adapter does not (yet) handle it.
pub fn classifyImport(interface: []const u8, func: []const u8) ?P2Op {
    for (table) |e| {
        if (std.mem.eql(u8, e.iface, interface) and std.mem.eql(u8, e.func, func)) return e.op;
    }
    return null;
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "classify: the stdout print path" {
    try testing.expectEqual(P2Op.cli_get_stdout, classifyImport("wasi:cli/stdout", "get-stdout").?);
    try testing.expectEqual(
        P2Op.out_stream_blocking_write_and_flush,
        classifyImport("wasi:io/streams", "[method]output-stream.blocking-write-and-flush").?,
    );
    try testing.expectEqual(P2Op.out_stream_drop, classifyImport("wasi:io/streams", "[resource-drop]output-stream").?);
}

test "p1Target: print path maps to fd_write(1) + std stream" {
    try testing.expectEqual(@as(u32, 1), p1Target(.cli_get_stdout).std_stream);
    try testing.expectEqual(@as(u32, 2), p1Target(.cli_get_stderr).std_stream);
    try testing.expectEqual(@as(u32, 1), p1Target(.out_stream_blocking_write_and_flush).fd_write);
    try testing.expectEqual(P1Target.noop, p1Target(.out_stream_drop));
    try testing.expectEqual(P1Target.proc_exit, p1Target(.cli_exit));
}

test "p1Target: clocks + random" {
    try testing.expectEqual(@as(u32, 0), p1Target(.clocks_wall_now).clock_time_get);
    try testing.expectEqual(@as(u32, 1), p1Target(.clocks_monotonic_now).clock_time_get);
    try testing.expectEqual(P1Target.random_get, p1Target(.random_get_bytes));
}

test "classify: filesystem descriptor resource ops (wasi:filesystem/types)" {
    try testing.expectEqual(P2Op.fs_descriptor_read, classifyImport("wasi:filesystem/types", "[method]descriptor.read").?);
    try testing.expectEqual(P2Op.fs_descriptor_write, classifyImport("wasi:filesystem/types", "[method]descriptor.write").?);
    try testing.expectEqual(P2Op.fs_descriptor_open_at, classifyImport("wasi:filesystem/types", "[method]descriptor.open-at").?);
    try testing.expectEqual(P2Op.fs_descriptor_sync, classifyImport("wasi:filesystem/types", "[method]descriptor.sync").?);
    try testing.expectEqual(P2Op.fs_descriptor_stat, classifyImport("wasi:filesystem/types", "[method]descriptor.stat").?);
    try testing.expectEqual(P2Op.fs_descriptor_get_type, classifyImport("wasi:filesystem/types", "[method]descriptor.get-type").?);
    try testing.expectEqual(P2Op.fs_descriptor_drop, classifyImport("wasi:filesystem/types", "[resource-drop]descriptor").?);
    try testing.expectEqual(P2Op.fs_get_directories, classifyImport("wasi:filesystem/preopens", "get-directories").?);
}

test "p1Target: descriptor ops map to fd syscalls (fd from the handle rep at call time)" {
    try testing.expectEqual(P1Target.fd_pread, p1Target(.fs_descriptor_read));
    try testing.expectEqual(P1Target.fd_pwrite, p1Target(.fs_descriptor_write));
    try testing.expectEqual(P1Target.path_open, p1Target(.fs_descriptor_open_at));
    try testing.expectEqual(P1Target.fd_sync, p1Target(.fs_descriptor_sync));
    try testing.expectEqual(P1Target.fd_filestat_get, p1Target(.fs_descriptor_stat));
    try testing.expectEqual(P1Target.fd_fdstat_get, p1Target(.fs_descriptor_get_type));
    try testing.expectEqual(P1Target.fd_close, p1Target(.fs_descriptor_drop));
    try testing.expectEqual(P1Target.preopens_get_directories, p1Target(.fs_get_directories));
}

test "classify: unknown interface/func → null; isWasiP2Interface" {
    try testing.expectEqual(@as(?P2Op, null), classifyImport("wasi:sockets/tcp", "connect"));
    try testing.expectEqual(@as(?P2Op, null), classifyImport("env", "foo"));
    try testing.expect(isWasiP2Interface("wasi:cli/run"));
    try testing.expect(!isWasiP2Interface("env"));
}
