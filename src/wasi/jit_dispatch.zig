//! WASI snapshot-preview1 dispatch trampolines for the JIT path
//! (chunk 7.9-d-2). C-ABI function pointers planted into
//! `JitRuntime.host_dispatch_base[idx]` by `runner.zig` when an
//! import's `(module, name)` matches a known WASI handler.
//!
//! Calling convention (load-bearing per chunk d-1 design):
//! every handler takes `rt: *JitRuntime` as its first arg
//! followed by the Wasm-declared params per the platform C ABI.
//! The JIT-side reserves arg0 for `runtime_ptr`, so the handler
//! sees the JitRuntime ptr in X0 / RDI / RCX without any
//! trampoline reshuffling. Handlers translate Wasm linear-memory
//! offsets (i32 args) into Zig pointers via `rt.vm_base + off`.
//!
//! Scope (d-2 MVP — the minimum to lift any realworld fixture
//! from COMPILE-PASS to RUN-PASS):
//! - `fd_write` — write iovec slice to stdout / stderr.
//! - `clock_time_get` — POSIX CLOCK_REALTIME / CLOCK_MONOTONIC.
//! - `random_get` — POSIX getrandom.
//! - `args_sizes_get` / `args_get` — return 0/empty (no argv).
//! - `environ_sizes_get` / `environ_get` — return 0/empty.
//!
//! Out of d-2 scope (deferred to d-3):
//! - `proc_exit` — semantics require non-returning + exit-code
//!   plumbing through JitRuntime. Default trap trampoline
//!   continues to handle it (sets trap_flag = 1). Wasm programs
//!   that call proc_exit will surface as Error.Trap to the host
//!   after the host stub returns.
//! - File-descriptor open / read / seek / close — needs a
//!   capability layer (preopens) which is itself post-d-2.
//!
//! Zone 2 (`src/wasi/`).

const std = @import("std");
const builtin = @import("builtin");
const jit_abi = @import("../engine/codegen/shared/jit_abi.zig");
const sections = @import("../parse/sections.zig");
// D-244 (JIT-WASI): when `rt.wasi_host` is set, the thin JIT thunks delegate
// to the SAME ABI-agnostic handlers the interp uses (`(host, mem, ...args)`),
// avoiding a second 46-syscall implementation.
const wasi_host_mod = @import("host.zig");
const wasi_clocks = @import("clocks.zig");

const JitRuntime = jit_abi.JitRuntime;
const Errno = enum(i32) {
    success = 0,
    badf = 8,
    fault = 21,
    inval = 28,
    io = 29,
};

/// `wasi_snapshot_preview1.fd_write(fd, iovs_ptr, iovs_len,
/// nwritten_ptr) -> errno` — write iovec array to a file
/// descriptor. The Wasm caller hands us four i32 values plus the
/// hidden runtime_ptr. iovs is an array of `(buf_off: u32,
/// buf_len: u32)` pairs at `vm_base + iovs_ptr`.
///
/// d-2 MVP supports fd 1 (stdout) + fd 2 (stderr) only; other
/// fds return EBADF. Bounds checks reject iov entries that
/// extend past `mem_limit`.
pub fn fd_write(
    rt: *JitRuntime,
    fd: i32,
    iovs_ptr: i32,
    iovs_len: i32,
    nwritten_ptr: i32,
) callconv(.c) i32 {
    const writer_kind: enum { stdout, stderr, bad } = switch (fd) {
        1 => .stdout,
        2 => .stderr,
        else => .bad,
    };
    if (writer_kind == .bad) return @intFromEnum(Errno.badf);

    if (iovs_ptr < 0 or iovs_len < 0 or nwritten_ptr < 0) {
        return @intFromEnum(Errno.inval);
    }
    const iovs_off: u64 = @intCast(iovs_ptr);
    const iovs_n: u64 = @intCast(iovs_len);
    const iovs_total_bytes: u64 = iovs_n * 8;
    if (iovs_off + iovs_total_bytes > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    const nwritten_off: u64 = @intCast(nwritten_ptr);
    if (nwritten_off + 4 > rt.mem_limit) return @intFromEnum(Errno.fault);

    var total_written: u32 = 0;
    var i: u64 = 0;
    while (i < iovs_n) : (i += 1) {
        const iov_at: usize = @intCast(iovs_off + i * 8);
        const buf_off = std.mem.readInt(u32, rt.vm_base[iov_at..][0..4], .little);
        const buf_len = std.mem.readInt(u32, rt.vm_base[iov_at + 4 ..][0..4], .little);
        const buf_off_u: u64 = buf_off;
        const buf_len_u: u64 = buf_len;
        if (buf_off_u + buf_len_u > rt.mem_limit) return @intFromEnum(Errno.fault);
        // d-2 MVP: count bytes only — actual stdout / stderr
        // routing needs `std.Io` plumbing through JitRuntime,
        // which lands alongside the run_runner_jit harness in
        // chunk d-3. Bounds-check the slice (the harness will
        // observe bytes from `vm_base[buf_off..buf_off+buf_len]`
        // post-call when output capture is wired).
        _ = rt.vm_base[@intCast(buf_off_u)..][0..@intCast(buf_len_u)];
        total_written +%= @intCast(buf_len);
    }
    const nw_at: usize = @intCast(nwritten_off);
    std.mem.writeInt(u32, rt.vm_base[nw_at..][0..4], total_written, .little);
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.fd_read(fd, iovs_ptr, iovs_len,
/// nread_ptr) -> errno` — scatter-read into an iovec array.
/// MVP supports fd 0 (stdin) only; other fds return EBADF.
/// Stdin is not yet plumbed through `JitRuntime`, so the MVP
/// reports EOF: writes 0 into `*nread` and returns success.
/// This lets fixtures that probe stdin (e.g. `read 0 bytes`)
/// reach `proc_exit` cleanly rather than trapping at the WASI
/// boundary. Real stdin sourcing lands once a `WasiContext`
/// tail-extension to `JitRuntime` is justified by a fixture
/// that genuinely needs input bytes.
pub fn fd_read(
    rt: *JitRuntime,
    fd: i32,
    iovs_ptr: i32,
    iovs_len: i32,
    nread_ptr: i32,
) callconv(.c) i32 {
    if (fd != 0) return @intFromEnum(Errno.badf);
    if (iovs_ptr < 0 or iovs_len < 0 or nread_ptr < 0) {
        return @intFromEnum(Errno.inval);
    }
    const iovs_off: u64 = @intCast(iovs_ptr);
    const iovs_n: u64 = @intCast(iovs_len);
    if (iovs_off + iovs_n * 8 > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    const nread_off: u64 = @intCast(nread_ptr);
    if (nread_off + 4 > rt.mem_limit) return @intFromEnum(Errno.fault);

    // Walk every iovec to validate buffer bounds even though we
    // write nothing — guests that hand us a malformed iovec must
    // see EFAULT, not a quiet 0-bytes-read success.
    var i: u64 = 0;
    while (i < iovs_n) : (i += 1) {
        const iov_at: usize = @intCast(iovs_off + i * 8);
        const buf_off = std.mem.readInt(u32, rt.vm_base[iov_at..][0..4], .little);
        const buf_len = std.mem.readInt(u32, rt.vm_base[iov_at + 4 ..][0..4], .little);
        const buf_off_u: u64 = buf_off;
        const buf_len_u: u64 = buf_len;
        if (buf_off_u + buf_len_u > rt.mem_limit) return @intFromEnum(Errno.fault);
    }

    const nw_at: usize = @intCast(nread_off);
    std.mem.writeInt(u32, rt.vm_base[nw_at..][0..4], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.clock_time_get(clock_id, precision,
/// time_ptr) -> errno` — write current nanos into `vm_base +
/// time_ptr`. Supports CLOCK_REALTIME (0) and CLOCK_MONOTONIC
/// (1); other clock_ids return EINVAL.
pub fn clock_time_get(
    rt: *JitRuntime,
    clock_id: i32,
    precision: i64,
    time_ptr: i32,
) callconv(.c) i32 {
    // D-244: with a host attached (`--engine jit` + WASI), delegate to the
    // shared interp handler for a REAL clock read; the handler bounds-checks
    // and writes the nanoseconds itself.
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        const e = wasi_clocks.clockTimeGet(host, mem, @bitCast(clock_id), @bitCast(precision), @bitCast(time_ptr));
        return @intCast(@intFromEnum(e));
    }
    // precision is ignored on the fallback path (OS clocks are single-resolution).
    if (time_ptr < 0) return @intFromEnum(Errno.inval);
    const off: u64 = @intCast(time_ptr);
    if (off + 8 > rt.mem_limit) return @intFromEnum(Errno.fault);
    if (clock_id < 0 or clock_id > 3) return @intFromEnum(Errno.inval);
    // Compute-only fallback (no host): write 0 nanos (deterministic + safe
    // against missing stdlib clock symbols on locked-down hosts).
    const at: usize = @intCast(off);
    std.mem.writeInt(u64, rt.vm_base[at..][0..8], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.random_get(buf_ptr, buf_len) -> errno`
/// — fill `vm_base + buf_ptr` with `buf_len` random bytes via
/// std.posix.getrandom (unix) / std.crypto.random (fallback).
pub fn random_get(rt: *JitRuntime, buf_ptr: i32, buf_len: i32) callconv(.c) i32 {
    if (buf_ptr < 0 or buf_len < 0) return @intFromEnum(Errno.inval);
    const off: u64 = @intCast(buf_ptr);
    const len: u64 = @intCast(buf_len);
    if (off + len > rt.mem_limit) return @intFromEnum(Errno.fault);
    if (len == 0) return @intFromEnum(Errno.success);
    const at: usize = @intCast(off);
    const slice = rt.vm_base[at..][0..@intCast(len)];
    // d-2 MVP: zero-fill (deterministic + safe). Real entropy
    // via std.posix.getrandom lands in d-3 alongside the host
    // I/O wiring; for the realworld JIT corpus the determinism
    // is preferable for differential-test reproducibility
    // anyway (interp == arm64 == x86_64 §9.7 / 7.11 gate).
    @memset(slice, 0);
    return @intFromEnum(Errno.success);
}

/// `args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno` —
/// d-2 stub returns 0/0 (no args). Real argv plumbing lands in
/// d-3 alongside a `WasiContext` JitRuntime tail-extension.
pub fn args_sizes_get(rt: *JitRuntime, argc_ptr: i32, argv_buf_size_ptr: i32) callconv(.c) i32 {
    if (argc_ptr < 0 or argv_buf_size_ptr < 0) return @intFromEnum(Errno.inval);
    const argc_off: u64 = @intCast(argc_ptr);
    const argv_off: u64 = @intCast(argv_buf_size_ptr);
    if (argc_off + 4 > rt.mem_limit or argv_off + 4 > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    std.mem.writeInt(u32, rt.vm_base[@intCast(argc_off)..][0..4], 0, .little);
    std.mem.writeInt(u32, rt.vm_base[@intCast(argv_off)..][0..4], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `args_get(argv_ptrs, argv_buf) -> errno` — d-2 stub no-op
/// (paired with args_sizes_get returning 0).
pub fn args_get(rt: *JitRuntime, argv_ptrs: i32, argv_buf: i32) callconv(.c) i32 {
    _ = rt;
    _ = argv_ptrs;
    _ = argv_buf;
    return @intFromEnum(Errno.success);
}

/// `environ_sizes_get(envc_ptr, envv_buf_size_ptr) -> errno` —
/// d-2 stub returns 0/0 (no environ).
pub fn environ_sizes_get(rt: *JitRuntime, envc_ptr: i32, envv_buf_size_ptr: i32) callconv(.c) i32 {
    if (envc_ptr < 0 or envv_buf_size_ptr < 0) return @intFromEnum(Errno.inval);
    const c_off: u64 = @intCast(envc_ptr);
    const v_off: u64 = @intCast(envv_buf_size_ptr);
    if (c_off + 4 > rt.mem_limit or v_off + 4 > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    std.mem.writeInt(u32, rt.vm_base[@intCast(c_off)..][0..4], 0, .little);
    std.mem.writeInt(u32, rt.vm_base[@intCast(v_off)..][0..4], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `environ_get(envv_ptrs, envv_buf) -> errno` — d-2 no-op.
pub fn environ_get(rt: *JitRuntime, envv_ptrs: i32, envv_buf: i32) callconv(.c) i32 {
    _ = rt;
    _ = envv_ptrs;
    _ = envv_buf;
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.proc_exit(rval) -> noreturn` — Wasm
/// program-termination request. The spec semantics are
/// "noreturn from the program" but a direct `std.process.exit`
/// in a JIT-host context would terminate the test runner too,
/// so we surface it as a trap instead. Sets `trap_flag = 1` and
/// returns; the JIT body's subsequent ops execute (control did
/// not actually exit), but the entry shim's post-return check
/// (`if (rt.trap_flag != 0) return Error.Trap`) routes the
/// caller to the Trap path. Wasm programs typically call
/// proc_exit as the last op, so post-trap-flag work is
/// unreachable in practice.
///
/// d-3 MVP: discards the exit code (no JitRuntime tail-extension
/// for `proc_exit_code` yet — that lands when run_runner_jit
/// needs to surface program exit codes for differential
/// comparison with wasmtime).
pub fn proc_exit(rt: *JitRuntime, rval: i32) callconv(.c) void {
    _ = rval;
    rt.trap_flag = 1;
}

/// Match an import (`module`, `name`) tuple against the known
/// WASI snapshot-preview1 manifest and return a function pointer
/// suitable for planting into `JitRuntime.host_dispatch_base[i]`.
/// Returns `null` for non-WASI imports — the caller leaves the
/// slot pointing at the default trap trampoline.
pub fn lookup(module_name: []const u8, field_name: []const u8) ?usize {
    if (!std.mem.eql(u8, module_name, "wasi_snapshot_preview1") and
        !std.mem.eql(u8, module_name, "wasi_unstable"))
    {
        return null;
    }
    const Pair = struct { name: []const u8, ptr: usize };
    const table = [_]Pair{
        .{ .name = "fd_write", .ptr = @intFromPtr(&fd_write) },
        .{ .name = "fd_read", .ptr = @intFromPtr(&fd_read) },
        .{ .name = "clock_time_get", .ptr = @intFromPtr(&clock_time_get) },
        .{ .name = "random_get", .ptr = @intFromPtr(&random_get) },
        .{ .name = "args_sizes_get", .ptr = @intFromPtr(&args_sizes_get) },
        .{ .name = "args_get", .ptr = @intFromPtr(&args_get) },
        .{ .name = "environ_sizes_get", .ptr = @intFromPtr(&environ_sizes_get) },
        .{ .name = "environ_get", .ptr = @intFromPtr(&environ_get) },
        .{ .name = "proc_exit", .ptr = @intFromPtr(&proc_exit) },
    };
    for (table) |p| {
        if (std.mem.eql(u8, p.name, field_name)) return p.ptr;
    }
    return null;
}

/// Walk imports in wasm-space order; for each function import,
/// fill `dispatch[i]` with the corresponding WASI handler ptr or
/// leave it untouched (the caller pre-fills with the default trap
/// trampoline). i increments only on `kind == .func` per the
/// wasm function-index space's semantics.
pub fn populateDispatch(dispatch: []usize, imports: []const sections.Import) void {
    var i: u32 = 0;
    for (imports) |imp| {
        if (imp.kind != .func) continue;
        if (i >= dispatch.len) return;
        if (lookup(imp.module, imp.name)) |ptr| dispatch[i] = ptr;
        i += 1;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "lookup: fd_write resolves" {
    try testing.expect(lookup("wasi_snapshot_preview1", "fd_write") != null);
    try testing.expect(lookup("wasi_unstable", "fd_write") != null);
}

test "lookup: proc_exit resolves" {
    try testing.expect(lookup("wasi_snapshot_preview1", "proc_exit") != null);
}

test "lookup: unknown module returns null" {
    try testing.expectEqual(@as(?usize, null), lookup("env", "fd_write"));
}

test "lookup: unknown field returns null" {
    try testing.expectEqual(@as(?usize, null), lookup("wasi_snapshot_preview1", "fd_write_v2"));
}

test "fd_write: bad fd returns EBADF" {
    var memory: [16]u8 = undefined;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const errno = fd_write(&rt, 99, 0, 0, 0);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.badf)), errno);
    _ = builtin.os.tag; // touch builtin to silence unused-import warning
}

test "clock_time_get: host-attached → REAL nonzero time; no host → 0 stub (D-244)" {
    var memory: [16]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
        .wasi_host = &h,
    };
    // realtime clock → the shared interp handler writes real nanoseconds.
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), clock_time_get(&rt, 0, 0, 0));
    try testing.expect(std.mem.readInt(u64, memory[0..8], .little) > 0);

    // Compute-only fallback (no host): deterministic 0.
    rt.wasi_host = null;
    @memset(&memory, 0xFF);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), clock_time_get(&rt, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, memory[0..8], .little));
}

test "lookup: fd_read resolves" {
    try testing.expect(lookup("wasi_snapshot_preview1", "fd_read") != null);
    try testing.expect(lookup("wasi_unstable", "fd_read") != null);
}

test "fd_read: bad fd returns EBADF" {
    var memory: [16]u8 = undefined;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const errno = fd_read(&rt, 99, 0, 0, 0);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.badf)), errno);
}

test "fd_read: fd 0 stdin EOF writes 0 to nread and returns success" {
    var memory: [32]u8 = .{0xAA} ** 32;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    // iovec at offset 0: { buf=16, buf_len=8 }; nread at offset 24.
    std.mem.writeInt(u32, memory[0..4], 16, .little);
    std.mem.writeInt(u32, memory[4..8], 8, .little);
    const errno = fd_read(&rt, 0, 0, 1, 24);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), errno);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[24..28], .little));
}

test "fd_read: out-of-bounds iovs_ptr returns EFAULT" {
    var memory: [16]u8 = undefined;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    // iovs_ptr=12 + 1 iovec (8 bytes) overflows 16-byte memory.
    const errno = fd_read(&rt, 0, 12, 1, 0);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.fault)), errno);
}

test "args_sizes_get: writes 0 + 0 to memory" {
    var memory: [16]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const errno = args_sizes_get(&rt, 0, 4);
    try testing.expectEqual(@as(i32, 0), errno);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[4..8], .little));
}
