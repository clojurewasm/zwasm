//! Reserve/commit linear-memory backing (ADR-0202 D1).
//!
//! Reserves a large PROT_NONE address range up front and commits an
//! RW prefix on demand, so a qualifying i32 linear memory can grow
//! IN PLACE — the base pointer never moves — and every byte past the
//! committed prefix (up to the reservation end) is a hardware guard
//! region: an access there faults instead of reading/writing, which
//! ADR-0202 D2 converts into the wasm `oob_memory` trap. Per-OS:
//!
//! - macOS / Linux: `mmap(PROT_NONE)` reserve (Linux adds
//!   `NORESERVE` so 8 GiB of reservation carries no commit charge),
//!   `mprotect(READ|WRITE)` commit.
//! - Windows x86_64: `NtAllocateVirtualMemory` MEM_RESERVE /
//!   MEM_COMMIT (mirrors `jit_mem.zig`'s ntdll usage; reserve-only
//!   pages consume address space, not the commit charge).
//!
//! Fresh anonymous pages are zero-filled by the OS on first touch,
//! which is exactly wasm's `memory.grow` zero-fill semantics — the
//! commit path therefore does NOT memset.
//!
//! Zone 0 (`src/platform/`) — depends only on Zig stdlib.

const std = @import("std");
const builtin = @import("builtin");
const trap_registry = @import("trap_registry.zig");

pub const Error = error{
    /// Address-space reservation failed (mmap / NtAllocateVirtualMemory).
    ReserveFailed,
    /// Committing an RW prefix failed (mprotect / MEM_COMMIT).
    CommitFailed,
    /// Host platform has no reserve/commit implementation.
    NotImplemented,
};

const posix_impl = (builtin.os.tag == .macos or builtin.os.tag == .linux);
const windows_impl = (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64);

/// True when this host can back a linear memory with a reserve/commit
/// region (ADR-0202 D1 qualifying hosts). Requires a 64-bit address
/// space — the i32 full reservation alone is 8 GiB of VA.
pub const supported: bool = @sizeOf(usize) == 8 and (posix_impl or windows_impl);

/// Reservation length that makes EVERY possible i32 memory access —
/// idx (≤ 2³²−1) + constant offset (≤ 2³²−1) + widest access (v128,
/// 16 bytes) — land inside reserved-but-guarded address space, so the
/// emitter may drop the bounds check entirely (ADR-0202 D4):
/// 4 GiB idx span + 4 GiB offset span + one 64 KiB tail page.
pub const i32_full_reservation: usize = if (supported)
    (1 << 32) + (1 << 32) + (64 * 1024)
else
    0;

/// Commit-rounding granularity. Mirrors `jit_mem.zig`: macOS
/// aarch64 pages are 16 KiB; everything else 4 KiB.
pub const page_size: usize = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
    16 * 1024
else
    4 * 1024;

/// A reserved region with a committed RW prefix. `base[0..committed]`
/// is readable/writable and zero-initialised; `base[committed..
/// reserve_len]` faults on access. Pair `reserve` with `release`.
pub const Reservation = struct {
    base: [*]align(page_size) u8,
    /// Total reserved length (bytes, page-rounded), guard included.
    reserve_len: usize,
    /// Committed RW prefix (bytes, page-rounded). Grows monotonically
    /// via `commit`; never shrinks (wasm memories never shrink).
    committed: usize,
};

fn roundUp(len: usize) usize {
    return (len + page_size - 1) & ~(page_size - 1);
}

/// Reserve `total_len` bytes (page-rounded) of inaccessible address
/// space. Nothing is committed yet — call `commit` before touching it.
///
/// Auto-registers `[base, base+rounded)` in the trap registry
/// (ADR-0202 D3) and `release` auto-unregisters — reserve/release IS
/// the single chokepoint, so no release path can leave a stale entry
/// that would misclassify a later fault at a reused address range.
pub fn reserve(total_len: usize) Error!Reservation {
    const r = try reserveRaw(total_len);
    trap_registry.registerGuarded(@intFromPtr(r.base), @intFromPtr(r.base) + r.reserve_len) catch {
        releaseRaw(r);
        return Error.ReserveFailed;
    };
    return r;
}

fn reserveRaw(total_len: usize) Error!Reservation {
    if (total_len == 0) return Error.ReserveFailed;
    const rounded = roundUp(total_len);

    if (comptime posix_impl) {
        const prot: std.posix.PROT = .{};
        // NORESERVE is Linux-specific (macOS never charges commit for
        // PROT_NONE anonymous mappings); without it a large reservation
        // can be refused under strict-overcommit settings.
        var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        if (comptime builtin.os.tag == .linux) flags.NORESERVE = true;
        const mem = std.posix.mmap(null, rounded, prot, flags, -1, 0) catch
            return Error.ReserveFailed;
        return .{ .base = @alignCast(mem.ptr), .reserve_len = rounded, .committed = 0 };
    }

    if (comptime windows_impl) {
        var base_addr: ?*anyopaque = null;
        var alloc_size: std.os.windows.SIZE_T = rounded;
        const status = std.os.windows.ntdll.NtAllocateVirtualMemory(
            std.os.windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            0,
            &alloc_size,
            .{ .RESERVE = true },
            .{ .NOACCESS = true },
        );
        if (status != .SUCCESS) return Error.ReserveFailed;
        const ptr = base_addr orelse return Error.ReserveFailed;
        return .{ .base = @ptrCast(@alignCast(ptr)), .reserve_len = rounded, .committed = 0 };
    }

    return Error.NotImplemented;
}

/// Grow the committed RW prefix so at least `min_committed` bytes are
/// accessible (rounded up to `page_size`). Monotonic: committing less
/// than the current prefix is a no-op. Newly committed pages read as
/// zero (OS anonymous-page guarantee). Caller must keep
/// `min_committed <= reserve_len` — the runtime's page-cap logic
/// (spec cap / declared max / host cap) guarantees it, so violating
/// it is a caller bug, not a recoverable state.
pub fn commit(r: *Reservation, min_committed: usize) Error!void {
    std.debug.assert(min_committed <= r.reserve_len);
    const target = roundUp(min_committed);
    if (target <= r.committed) return;

    if (comptime posix_impl) {
        // `std.c.mprotect`: Zig 0.16's std.posix dropped its mprotect
        // wrapper, and macOS has no non-libc syscall path — ADR-0070
        // necessary (amendment B133, ADR-0202 D1).
        const delta_base: *align(page_size) anyopaque = @ptrCast(@alignCast(r.base + r.committed));
        if (std.c.mprotect(delta_base, target - r.committed, .{ .READ = true, .WRITE = true }) != 0)
            return Error.CommitFailed;
        r.committed = target;
        return;
    }

    if (comptime windows_impl) {
        // MEM_COMMIT on an already-committed subrange is a no-op, so
        // committing [0..target) (not just the delta) is safe and
        // avoids tracking the delta base separately. MSDN
        // (NtAllocateVirtualMemory / VirtualAlloc, MEM_COMMIT).
        var base_addr: ?*anyopaque = r.base;
        var alloc_size: std.os.windows.SIZE_T = target;
        const status = std.os.windows.ntdll.NtAllocateVirtualMemory(
            std.os.windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            0,
            &alloc_size,
            .{ .COMMIT = true },
            .{ .READWRITE = true },
        );
        if (status != .SUCCESS) return Error.CommitFailed;
        r.committed = target;
        return;
    }

    return Error.NotImplemented;
}

/// Release the whole reservation (committed prefix + guard region).
pub fn release(r: Reservation) void {
    if (r.reserve_len == 0) return;
    trap_registry.unregisterGuarded(@intFromPtr(r.base));
    releaseRaw(r);
}

fn releaseRaw(r: Reservation) void {
    if (r.reserve_len == 0) return;
    if (comptime posix_impl) {
        std.posix.munmap(r.base[0..r.reserve_len]);
        return;
    }
    if (comptime windows_impl) {
        // MEM_RELEASE requires size = 0 and the original reservation
        // base (mirrors `jit_mem.free`).
        var addr: ?*anyopaque = r.base;
        var size: std.os.windows.SIZE_T = 0;
        _ = std.os.windows.ntdll.NtFreeVirtualMemory(
            std.os.windows.GetCurrentProcess(),
            @ptrCast(&addr),
            &size,
            .{ .RELEASE = true },
        );
        return;
    }
}

// -----------------------------------------------------------
// Tests. All 3 gate OSes satisfy `supported`; the comptime gate
// below only prunes wasi/32-bit builds (ADR-0202 D1 host list).
// -----------------------------------------------------------

const testing = std.testing;

test "guarded_mem: reserve → commit → write/read → grow commit → release roundtrip" {
    if (comptime !supported) return; // comptime platform prune (ADR-0122 D3) — ADR-0202 D1 host list
    var r = try reserve(1 << 20); // 1 MiB reservation, small for test speed
    defer release(r);
    try testing.expectEqual(@as(usize, 0), r.committed);

    try commit(&r, 3 * page_size);
    try testing.expect(r.committed >= 3 * page_size);
    // Fresh pages are zero-filled by the OS (the wasm grow contract).
    try testing.expectEqual(@as(u8, 0), r.base[0]);
    try testing.expectEqual(@as(u8, 0), r.base[3 * page_size - 1]);
    r.base[0] = 0xAB;
    r.base[3 * page_size - 1] = 0xCD;
    try testing.expectEqual(@as(u8, 0xAB), r.base[0]);
    try testing.expectEqual(@as(u8, 0xCD), r.base[3 * page_size - 1]);

    // In-place growth: base pointer must not move (the ADR-0202 D1
    // property the JIT's pinned vm_base relies on).
    const base_before = r.base;
    try commit(&r, 8 * page_size);
    try testing.expectEqual(base_before, r.base);
    try testing.expectEqual(@as(u8, 0xAB), r.base[0]); // old data intact
    try testing.expectEqual(@as(u8, 0), r.base[8 * page_size - 1]); // new pages zero
}

test "guarded_mem: commit is monotonic (smaller request is a no-op)" {
    if (comptime !supported) return; // comptime platform prune (ADR-0122 D3) — ADR-0202 D1 host list
    var r = try reserve(1 << 20);
    defer release(r);
    try commit(&r, 4 * page_size);
    const committed_before = r.committed;
    try commit(&r, page_size);
    try testing.expectEqual(committed_before, r.committed);
}

test "guarded_mem: reserve(0) is refused" {
    if (comptime !supported) return; // comptime platform prune (ADR-0122 D3) — ADR-0202 D1 host list
    try testing.expectError(Error.ReserveFailed, reserve(0));
}

/// Child-side fault handler for the guard test below: exit with a
/// distinct code so the parent can tell "faulted as expected" (42)
/// from "no fault" (0) — and so the child never reaches the test
/// runner's own crash handler (whose stderr trace + re-raise confuse
/// the harness; same rationale as `signal.zig`'s fork test).
fn guardTestFaultExit(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    std.c._exit(42);
}

test "guarded_mem: access past the committed prefix faults (guard actually guards)" {
    // fork a child that arms a fault→_exit(42) handler and touches the
    // first guard byte; the parent asserts exit code 42 (the fault
    // fired). fork/waitpid/_exit = ADR-0070 necessary (test-only),
    // mirroring `signal.zig`'s fork-recovery test.
    if (comptime !(supported and builtin.os.tag != .windows)) return; // comptime platform prune (ADR-0122 D3) — POSIX fork test; Win64 guard verified via the D2 handler tests (ADR-0202)
    var r = try reserve(1 << 20);
    defer release(r);
    try commit(&r, page_size);

    const pid = std.c.fork();
    try testing.expect(pid != -1);
    if (pid == 0) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = guardTestFaultExit },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        std.posix.sigaction(.SEGV, &act, null);
        std.posix.sigaction(.BUS, &act, null); // macOS reports guard hits as SIGBUS
        const guard_byte: *volatile u8 = @ptrCast(&r.base[r.committed]);
        guard_byte.* = 1; // must fault — first byte past the committed prefix
        std.c._exit(0); // unreachable when the guard works
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    try testing.expect(std.posix.W.IFEXITED(ustatus));
    try testing.expectEqual(@as(u32, 42), std.posix.W.EXITSTATUS(ustatus));
}
