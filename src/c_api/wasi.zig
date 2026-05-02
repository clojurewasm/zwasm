//! WASI-side of the C ABI binding (§9.5 / 5.0 carve-out from
//! `wasm_c_api.zig` per ADR-0007).
//!
//! Holds the host thunks that bridge guest WASI calls into the
//! `src/wasi/*.zig` handlers, the dispatcher
//! (`lookupWasiThunk`), and the standalone `zwasm_wasi_config_*`
//! C exports. `zwasm_store_set_wasi` stays in `wasm_c_api.zig`
//! because it touches the `Store` shape; it moves later with
//! `instance.zig`.
//!
//! Zone 3 — same as the rest of `src/c_api/`. May import any
//! lower zone (`interp/`, `wasi/`).

const std = @import("std");
const interp = @import("../interp/mod.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_proc = @import("../wasi/proc.zig");
const wasi_clocks = @import("../wasi/clocks.zig");
const Errno = @import("../wasi/p1.zig").Errno;

const testing = std.testing;

// ============================================================
// WASI host config (§9.4 / 4.7 chunk a)
// ============================================================

/// `zwasm_wasi_config_new()` — allocate a fresh WASI host
/// config (the `zwasm_wasi_config_t` opaque type from
/// `include/wasi.h`). Internally aliases to `wasi_host.Host`.
/// Caller owns until `zwasm_store_set_wasi` transfers
/// ownership to a Store, OR until `zwasm_wasi_config_delete`.
///
/// Allocator: pinned to the engine's allocator path is not
/// possible since this function does not take an Engine. Uses
/// `std.heap.c_allocator` so the resulting Host is freeable
/// either through `_delete` here or through `wasm_store_delete`
/// once installed.
pub export fn zwasm_wasi_config_new() callconv(.c) ?*wasi_host.Host {
    const alloc = std.heap.c_allocator;
    const h = alloc.create(wasi_host.Host) catch return null;
    h.* = wasi_host.Host.init(alloc) catch {
        alloc.destroy(h);
        return null;
    };
    return h;
}

/// `zwasm_wasi_config_delete(*Host)` — free a config that was
/// NOT installed on a Store. Null-tolerant. After
/// `zwasm_store_set_wasi` consumes the config, the C host
/// must NOT call this on the same pointer.
pub export fn zwasm_wasi_config_delete(h: ?*wasi_host.Host) callconv(.c) void {
    const handle = h orelse return;
    handle.deinit();
    std.heap.c_allocator.destroy(handle);
}

// ============================================================
// WASI host thunks (§9.4 / 4.7 chunk c)
// ============================================================
//
// Each thunk pops the guest-call args off the operand stack
// (right-to-left, since Wasm pushes left-to-right), invokes the
// corresponding `src/wasi/*.zig` handler with `host` + `mem` +
// the args, and pushes the resulting Errno back as an i32.
// `proc_exit` is the odd one out: returns `error.WasiExit` so
// the dispatch loop unwinds with `host.exit_code` set.

/// Type-erased thunk pointer surface. The `*anyopaque` ctx is
/// the `*wasi_host.Host` installed on the Store at
/// instantiation time.
pub const HostThunkFn = *const fn (*interp.Runtime, *anyopaque) anyerror!void;

fn thunkFdWrite(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nwritten_ptr = rt.popOperand().u32;
    const ciovec_count = rt.popOperand().u32;
    const ciovec_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    const errno = wasi_fd.fdWrite(host, rt.memory, fd, ciovec_ptr, ciovec_count, nwritten_ptr);
    try rt.pushOperand(.{ .i32 = @intCast(@intFromEnum(errno)) });
}

fn thunkProcExit(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const rval = rt.popOperand().u32;
    _ = wasi_proc.procExit(host, rval);
    return error.WasiExit;
}

fn pushErrno(rt: *interp.Runtime, errno: Errno) !void {
    try rt.pushOperand(.{ .i32 = @intCast(@intFromEnum(errno)) });
}

// args / environ thunks
fn thunkArgsSizesGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const buf_size_ptr = rt.popOperand().u32;
    const argc_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.argsSizesGet(host, rt.memory, argc_ptr, buf_size_ptr));
}
fn thunkArgsGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const argv_buf_ptr = rt.popOperand().u32;
    const argv_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.argsGet(host, rt.memory, argv_ptr, argv_buf_ptr));
}
fn thunkEnvironSizesGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const buf_size_ptr = rt.popOperand().u32;
    const count_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.environSizesGet(host, rt.memory, count_ptr, buf_size_ptr));
}
fn thunkEnvironGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const environ_buf_ptr = rt.popOperand().u32;
    const environ_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.environGet(host, rt.memory, environ_ptr, environ_buf_ptr));
}

// clock / random / poll thunks
fn thunkClockTimeGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const time_ptr = rt.popOperand().u32;
    const precision = rt.popOperand().u64;
    const clock_id = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.clockTimeGet(host, rt.memory, clock_id, precision, time_ptr));
}
fn thunkRandomGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const buf_len = rt.popOperand().u32;
    const buf_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.randomGet(host, rt.memory, buf_ptr, buf_len));
}
fn thunkPollOneoff(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nevents_ptr = rt.popOperand().u32;
    const nsubscriptions = rt.popOperand().u32;
    const out_ptr = rt.popOperand().u32;
    const in_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.pollOneoff(host, rt.memory, in_ptr, out_ptr, nsubscriptions, nevents_ptr));
}

// fd thunks
fn thunkFdRead(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nread_ptr = rt.popOperand().u32;
    const iovec_count = rt.popOperand().u32;
    const iovec_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdRead(host, rt.memory, fd, iovec_ptr, iovec_count, nread_ptr));
}
fn thunkFdClose(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdClose(host, fd));
}
fn thunkFdSeek(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const new_pos_ptr = rt.popOperand().u32;
    const whence: u8 = @intCast(rt.popOperand().u32 & 0xFF);
    const offset = rt.popOperand().i64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdSeek(host, rt.memory, fd, offset, whence, new_pos_ptr));
}
fn thunkFdTell(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const pos_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdTell(host, rt.memory, fd, pos_ptr));
}
fn thunkFdFdstatGet(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fdstat_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFdstatGet(host, rt.memory, fd, fdstat_ptr));
}
fn thunkFdFdstatSetFlags(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const flags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFdstatSetFlags(host, fd, flags));
}
fn thunkPathOpen(rt: *interp.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const opened_fd_ptr = rt.popOperand().u32;
    const fdflags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const fs_rights_inheriting = rt.popOperand().u64;
    const fs_rights_base = rt.popOperand().u64;
    const oflags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirflags = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.pathOpen(host, rt.memory, dirfd, dirflags, path_ptr, path_len, oflags, fs_rights_base, fs_rights_inheriting, fdflags, opened_fd_ptr));
}

/// Map a WASI snapshot-1 import name to its host thunk, or
/// null if the name is outside the supported set.
pub fn lookupWasiThunk(name: []const u8) ?HostThunkFn {
    if (std.mem.eql(u8, name, "fd_write")) return thunkFdWrite;
    if (std.mem.eql(u8, name, "proc_exit")) return thunkProcExit;
    if (std.mem.eql(u8, name, "args_get")) return thunkArgsGet;
    if (std.mem.eql(u8, name, "args_sizes_get")) return thunkArgsSizesGet;
    if (std.mem.eql(u8, name, "environ_get")) return thunkEnvironGet;
    if (std.mem.eql(u8, name, "environ_sizes_get")) return thunkEnvironSizesGet;
    if (std.mem.eql(u8, name, "clock_time_get")) return thunkClockTimeGet;
    if (std.mem.eql(u8, name, "random_get")) return thunkRandomGet;
    if (std.mem.eql(u8, name, "poll_oneoff")) return thunkPollOneoff;
    if (std.mem.eql(u8, name, "fd_read")) return thunkFdRead;
    if (std.mem.eql(u8, name, "fd_close")) return thunkFdClose;
    if (std.mem.eql(u8, name, "fd_seek")) return thunkFdSeek;
    if (std.mem.eql(u8, name, "fd_tell")) return thunkFdTell;
    if (std.mem.eql(u8, name, "fd_fdstat_get")) return thunkFdFdstatGet;
    if (std.mem.eql(u8, name, "fd_fdstat_set_flags")) return thunkFdFdstatSetFlags;
    if (std.mem.eql(u8, name, "path_open")) return thunkPathOpen;
    return null;
}

// ============================================================
// Tests
// ============================================================

test "zwasm_wasi_config_delete: standalone (not installed on Store) is leak-free" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_wasi_config_delete(cfg);
}

test "zwasm_wasi_config_delete: null-arg discipline" {
    zwasm_wasi_config_delete(null);
}

test "lookupWasiThunk: every supported WASI 0.1 import resolves" {
    const names = [_][]const u8{
        "fd_write",        "proc_exit",
        "args_get",        "args_sizes_get",
        "environ_get",     "environ_sizes_get",
        "clock_time_get",  "random_get",
        "poll_oneoff",
        "fd_read",         "fd_close",
        "fd_seek",         "fd_tell",
        "fd_fdstat_get",   "fd_fdstat_set_flags",
        "path_open",
    };
    inline for (names) |n| {
        try testing.expect(lookupWasiThunk(n) != null);
    }
    try testing.expect(lookupWasiThunk("does_not_exist") == null);
}
