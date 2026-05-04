//! WASI 0.1 clock / random / poll handlers (§9.4 / 4.6).
//!
//! All three are low-IO syscalls that map onto Zig stdlib
//! primitives:
//!
//! - `clock_time_get(clock_id, precision, *time_out) → errno`
//!   reads the host's monotonic / realtime clock and writes
//!   nanoseconds-since-epoch into the guest pointer.
//! - `random_get(buf_ptr, buf_len) → errno` fills guest memory
//!   with cryptographic random bytes.
//! - `poll_oneoff(in_ptr, out_ptr, nsubscriptions, *nevents_out)
//!   → errno` — minimal stdin-only stub; with `nsubscriptions
//!   == 0` writes `nevents_out = 0`. Larger fan-outs return
//!   `notsup` until the §9.4 / 4.10 realworld diff calls for
//!   them.
//!
//! Zone 2 (`src/wasi/`) — siblings: p1.zig / host.zig /
//! proc.zig / fd.zig.

const std = @import("std");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

// ============================================================
// Memory helpers
// ============================================================

fn writeU32LE(mem: []u8, offset: u32, value: u32) p1.Errno {
    if (@as(usize, offset) + 4 > mem.len) return .fault;
    std.mem.writeInt(u32, mem[offset..][0..4], value, .little);
    return .success;
}

fn writeU64LE(mem: []u8, offset: u32, value: u64) p1.Errno {
    if (@as(usize, offset) + 8 > mem.len) return .fault;
    std.mem.writeInt(u64, mem[offset..][0..8], value, .little);
    return .success;
}

// ============================================================
// clock_time_get
// ============================================================

/// `clock_time_get(clock_id, precision, *time_out) → errno`.
/// Spec-conformant clock IDs (see witx `clockid`):
///   - 0 realtime          → `std.Io.Clock.real`
///   - 1 monotonic         → `std.Io.Clock.awake`
///   - 2 process_cputime   → `std.Io.Clock.cpu_process`
///   - 3 thread_cputime    → `std.Io.Clock.cpu_thread`
///
/// `precision` is advisory (witx: "max permissible allowable
/// error in nanoseconds"). Ignored; we return the host's
/// native resolution.
///
/// Requires `host.io` to be set; without it returns `nosys`
/// (Zig 0.16 routes all clock reads through `std.Io`).
pub fn clockTimeGet(
    host: *Host,
    mem: []u8,
    clock_id: u32,
    precision: u64,
    time_ptr: u32,
) p1.Errno {
    _ = precision;
    const io = host.io orelse return .nosys;
    const clock: std.Io.Clock = switch (clock_id) {
        0 => .real,
        1 => .awake,
        2 => .cpu_process,
        3 => .cpu_thread,
        else => return .inval,
    };
    const ts = std.Io.Timestamp.now(io, clock);
    const ns_i = ts.toNanoseconds();
    if (ns_i < 0) return .inval;
    const ns_u: u64 = @intCast(@min(ns_i, std.math.maxInt(u64)));
    return writeU64LE(mem, time_ptr, ns_u);
}

// ============================================================
// random_get
// ============================================================

/// `random_get(buf_ptr, buf_len) → errno` — fill guest memory
/// with cryptographic random bytes. Uses `std.Io.randomSecure`
/// (Zig 0.16 routes randomness through `std.Io`). Out-of-bounds
/// buf returns `fault`; allocator failures inside the io vtable
/// surface as `nosys`.
pub fn randomGet(
    host: *Host,
    mem: []u8,
    buf_ptr: u32,
    buf_len: u32,
) p1.Errno {
    const end = @as(usize, buf_ptr) + @as(usize, buf_len);
    if (end > mem.len) return .fault;
    if (buf_len == 0) return .success;
    const io = host.io orelse return .nosys;
    io.randomSecure(mem[buf_ptr..end]) catch return .nosys;
    return .success;
}

// ============================================================
// poll_oneoff
// ============================================================

/// `poll_oneoff(in_ptr, out_ptr, nsubscriptions,
/// *nevents_out) → errno` — stub. With `nsubscriptions == 0`
/// writes `nevents_out = 0` (vacuously satisfied poll). Any
/// non-zero subscription count returns `notsup` until §9.4 /
/// 4.10's realworld samples surface a guest that genuinely
/// needs polling.
pub fn pollOneoff(
    _: *Host,
    mem: []u8,
    in_ptr: u32,
    out_ptr: u32,
    nsubscriptions: u32,
    nevents_ptr: u32,
) p1.Errno {
    _ = in_ptr;
    _ = out_ptr;
    if (nsubscriptions != 0) return .notsup;
    return writeU32LE(mem, nevents_ptr, 0);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "clockTimeGet: realtime writes non-zero u64" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 0, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    const ns = std.mem.readInt(u64, mem[0..8], .little);
    try testing.expect(ns > 0);
}

test "clockTimeGet: monotonic also writes a u64" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 1, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expect(std.mem.readInt(u64, mem[0..8], .little) > 0);
}

test "clockTimeGet: unknown clock_id returns inval" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 99, 0, 0);
    try testing.expectEqual(p1.Errno.inval, e);
}

test "clockTimeGet: out-of-bounds time_ptr returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [4]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 0, 0, 0);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "clockTimeGet: missing host.io returns nosys" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 0, 0, 0);
    try testing.expectEqual(p1.Errno.nosys, e);
}

test "randomGet: fills 32 bytes with at least one non-zero byte" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [32]u8 = @splat(0);
    const e = randomGet(&h, &mem, 0, 32);
    try testing.expectEqual(p1.Errno.success, e);
    var any_nonzero = false;
    for (mem) |b| {
        if (b != 0) {
            any_nonzero = true;
            break;
        }
    }
    try testing.expect(any_nonzero);
}

test "randomGet: zero-length buf is success-noop" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [4]u8 = @splat(0xAB);
    const e = randomGet(&h, &mem, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    // Memory untouched.
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xAB, 0xAB, 0xAB }, &mem);
}

test "randomGet: out-of-bounds buf returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = randomGet(&h, &mem, 10, 20);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "pollOneoff: zero subscriptions writes nevents=0" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [8]u8 = @splat(0xFF);
    const e = pollOneoff(&h, &mem, 0, 0, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, mem[0..4], .little));
}

test "pollOneoff: non-zero subscriptions returns notsup" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [8]u8 = @splat(0);
    const e = pollOneoff(&h, &mem, 0, 0, 1, 0);
    try testing.expectEqual(p1.Errno.notsup, e);
}
