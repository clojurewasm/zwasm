//! Cross-platform thread-stack-limit query for the JIT-prologue
//! stack-probe (ADR-0105 D1).
//!
//! Returns the lowest stack-address the JIT body should treat as
//! safe to operate above, plus the chosen `STACK_GUARD_HEADROOM`
//! margin. The JIT prologue (cycle 2) emits `cmp sp, stack_limit
//! + b.ls stack_overflow_trap_stub` — when SP descends below this
//! threshold the function traps cleanly via the existing trap-
//! stub path BEFORE the OS-level guard page faults.
//!
//! Per-platform syscall:
//!
//! - macOS: `pthread_get_stackaddr_np` + `pthread_get_stacksize_np`.
//!   The address returned is the high-end of the stack region; the
//!   low-end (where overflow happens) is `addr - size`.
//! - Linux (glibc): `pthread_getattr_np` + `pthread_attr_getstack`.
//!   Returns `(low-end, size)` directly. `pthread_attr_destroy`
//!   releases the attr struct.
//! - Windows: `GetCurrentThreadStackLimits(low, high)` (Win 8+).
//!   Returns the low and high stack bounds for the current thread.
//!
//! All three return 0 ("stack-probe disabled" sentinel) on syscall
//! failure — the prologue interprets 0 as "always pass" since SP
//! is always > 0, so the runtime gracefully degrades to the
//! pre-probe behaviour. Per `.claude/rules/platform_panic_vs_error.md`
//! @panic is reserved for genuinely unreachable platforms; we
//! prefer graceful disable here so an unsupported host can still
//! run code that doesn't recurse deeply.
//!
//! libc symbols added to ADR-0070 necessary-category at this
//! commit (cycle 1 of ADR-0105 implementation). See
//! `.dev/decisions/0070_libc_boundary.md` Revision history.
//!
//! Zone 0 (`src/platform/`).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Headroom kept above the actual stack low-end for trap-stub
/// epilogue, signal-handler frame, and recovery state. Per
/// ADR-0105 D6 — initial conservative value; tunable per amend.
///
/// R3 cycle 6 (2026-05-23): Win64 path bumped to 1 MiB
/// experimentally. Mac+Linux runaway test trapped at 16 KiB
/// successfully; Win64 runaway crashed STACK_OVERFLOW (exit 253)
/// despite probe + stack_limit being correctly written (via_off
/// cross-check passed in cycle 4). One remaining hypothesis is a
/// Win64 commit-pattern early-overflow where the OS raises
/// `EXCEPTION_STACK_OVERFLOW` BEFORE SP descends to `low + 16K`.
/// A 1 MiB headroom would make the probe fire WELL before any
/// Windows commit boundary. If the probe still doesn't fire at
/// 1 MiB, the bug is in the probe instruction stream execution
/// itself (not stack-limit value).
pub const STACK_GUARD_HEADROOM: usize = if (builtin.os.tag == .windows)
    1024 * 1024
else
    16 * 1024;

/// Sentinel returned when the per-platform query fails OR the
/// platform isn't supported. The JIT prologue treats `0` as
/// "always pass" (SP > 0 always), gracefully disabling the probe.
pub const disabled: usize = 0;

/// Compute the stack-limit threshold for the current thread.
/// Add `headroom` to the actual stack low-end so the trap-stub
/// has room to run after the probe fires.
///
/// Returns `disabled` (= 0) on platforms without a supported
/// query OR when the per-platform call fails.
pub fn computeStackLimit(headroom: usize) usize {
    if (comptime builtin.os.tag == .macos) {
        return computeMacos(headroom);
    } else if (comptime builtin.os.tag == .linux) {
        return computeLinux(headroom);
    } else if (comptime builtin.os.tag == .windows) {
        return computeWindows(headroom);
    } else {
        return disabled;
    }
}

// ============================================================
// macOS
// ============================================================

extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;

fn computeMacos(headroom: usize) usize {
    const self = std.c.pthread_self();
    const high_opt = pthread_get_stackaddr_np(self);
    const high_ptr = high_opt orelse return disabled;
    const high = @intFromPtr(high_ptr);
    const size = pthread_get_stacksize_np(self);
    if (size == 0 or size > high) return disabled;
    return high - size + headroom;
}

// ============================================================
// Linux (glibc)
// ============================================================

const PthreadAttr = extern struct {
    // glibc pthread_attr_t is opaque-by-size (56 bytes on
    // x86_64 glibc). Zig's `std.c.pthread_attr_t` would normally
    // surface this but is not exposed on all platforms; use a
    // raw byte buffer big enough for the ABI.
    _opaque: [64]u8 align(8),
};

extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *PthreadAttr) c_int;
extern "c" fn pthread_attr_getstack(attr: *const PthreadAttr, stackaddr: *?*anyopaque, stacksize: *usize) c_int;
extern "c" fn pthread_attr_destroy(attr: *PthreadAttr) c_int;

fn computeLinux(headroom: usize) usize {
    var attr: PthreadAttr = .{ ._opaque = [_]u8{0} ** 64 };
    if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return disabled;
    defer _ = pthread_attr_destroy(&attr);
    var low_opt: ?*anyopaque = null;
    var size: usize = 0;
    if (pthread_attr_getstack(&attr, &low_opt, &size) != 0) return disabled;
    const low_ptr = low_opt orelse return disabled;
    const low = @intFromPtr(low_ptr);
    if (size == 0) return disabled;
    return low + headroom;
}

// ============================================================
// Windows
// ============================================================

extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;

fn computeWindows(headroom: usize) usize {
    var low: usize = 0;
    var high: usize = 0;
    GetCurrentThreadStackLimits(&low, &high);
    if (low == 0 or high <= low) return disabled;
    return low + headroom;
}

// ============================================================
// Native-stack HIGH end (for the §15.1 conservative GC root scan)
// ============================================================

/// Top-of-stack address of the current thread — the upper bound for
/// the conservative GC native-stack scan (ADR-0128 §2 / §15.1): the
/// scan walks `[current SP, nativeStackHigh())` for words that look
/// like live `GcRef`s and conservatively marks them, covering refs
/// held in JIT/host native frames that the precise interp root walk
/// does not see. Reuses the same per-platform pthread/TIB queries as
/// `computeStackLimit` (which returns the LOW limit). Returns `0`
/// (disabled) on query failure / unsupported platform — the caller
/// then skips the native-stack scan (the interp walk still runs, so
/// correctness is preserved under the non-moving no-reclaim model).
pub fn nativeStackHigh() usize {
    if (comptime builtin.os.tag == .macos) {
        const high_opt = pthread_get_stackaddr_np(std.c.pthread_self());
        return @intFromPtr(high_opt orelse return 0);
    } else if (comptime builtin.os.tag == .linux) {
        var attr: PthreadAttr = .{ ._opaque = [_]u8{0} ** 64 };
        if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return 0;
        defer _ = pthread_attr_destroy(&attr);
        var low_opt: ?*anyopaque = null;
        var size: usize = 0;
        if (pthread_attr_getstack(&attr, &low_opt, &size) != 0) return 0;
        const low = @intFromPtr(low_opt orelse return 0);
        return low + size;
    } else if (comptime builtin.os.tag == .windows) {
        var low: usize = 0;
        var high: usize = 0;
        GetCurrentThreadStackLimits(&low, &high);
        return high;
    } else {
        return 0;
    }
}

// ============================================================
// Diagnostic
// ============================================================

/// ADR-0105 R3 diagnostic: per-call stderr report of the
/// JIT-prologue stack-probe context (`stack_limit` value, current
/// approximate SP, margin) on Win64. Other hosts fire once per
/// thread to avoid spamming the spec runner stdout. Permanent per
/// `.claude/rules/extended_challenge.md` Step 5 — multi-cycle
/// Win64 stack-probe investigation needs per-fixture evidence
/// (margin at `assert_exhaustion runaway` specifically vs initial
/// thread entry).
threadlocal var diag_seen: bool = false;

pub fn diagOnce(stack_limit_value: usize) void {
    diagOnceRaw(stack_limit_value, null, 0);
}

/// R3 cycle 4 variant: cross-checks `*(rt + off)` (= what the JIT
/// probe reads) against the direct `stack_limit_value` (= what
/// `invokeAndCheck` just wrote via field syntax). If they disagree
/// on Win64, `stack_limit_off` is wrong relative to the actual
/// extern-struct layout.
pub fn diagOnceWithRt(rt_ptr: *const anyopaque, stack_limit_off: usize, stack_limit_value: usize) void {
    diagOnceRaw(stack_limit_value, rt_ptr, stack_limit_off);
}

fn diagOnceRaw(stack_limit_value: usize, rt_ptr: ?*const anyopaque, stack_limit_off: usize) void {
    // Leftover Win64 stack-probe investigation print (D-245). Gated behind the
    // `-Dtrace-stackprobe` build option (default false; ADR-0164 B / D-292) so
    // even Debug `zig build test` stderr is clean — it fired once per process on
    // the first JIT call, polluting every test's output. D-279 Win64 work
    // re-enables via `-Dtrace-stackprobe=true`.
    if (comptime !build_options.trace_stackprobe) return;
    // Once per thread on all hosts. Cycle 3's "per call on Win64"
    // override was retired after R3 cycle 6 root-cause (Windows
    // commit-pattern early-overflow) — no longer need to flood
    // stderr per fixture; the once-flag is sufficient evidence.
    if (diag_seen) return;
    diag_seen = true;
    var sp: usize = 0;
    if (comptime builtin.cpu.arch == .x86_64) {
        sp = asm volatile ("mov %%rsp, %[sp]"
            : [sp] "=r" (-> usize),
        );
    } else if (comptime builtin.cpu.arch == .aarch64) {
        sp = asm volatile ("mov %[sp], sp"
            : [sp] "=r" (-> usize),
        );
    }
    const margin: usize = if (stack_limit_value > 0 and sp >= stack_limit_value)
        sp - stack_limit_value
    else
        0;
    var via_off_value: usize = 0;
    if (rt_ptr) |p| {
        const base: [*]const u8 = @ptrCast(p);
        const slot: *const usize = @ptrCast(@alignCast(base + stack_limit_off));
        via_off_value = slot.*;
    }
    std.debug.print(
        "[stack_probe] stack_limit=0x{x} sp=0x{x} margin=0x{x} via_off=0x{x} off={d} rt=0x{x} os={s} arch={s}\n",
        .{
            stack_limit_value,
            sp,
            margin,
            via_off_value,
            stack_limit_off,
            if (rt_ptr) |p| @intFromPtr(p) else 0,
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
        },
    );
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "computeStackLimit: returns non-zero on supported hosts (Mac / Linux / Windows)" {
    const limit = computeStackLimit(STACK_GUARD_HEADROOM);
    if (builtin.os.tag == .macos or builtin.os.tag == .linux or builtin.os.tag == .windows) {
        // The current call's SP must be above the limit (otherwise the
        // caller would have overflowed already). Probes the same
        // invariant the JIT prologue will rely on.
        try testing.expect(limit > 0);
        const sp_probe: usize = @intFromPtr(&limit); // a local's address is on the stack
        try testing.expect(sp_probe > limit);
    } else {
        // Unsupported platforms return the `disabled` sentinel.
        try testing.expectEqual(disabled, limit);
    }
}

test "STACK_GUARD_HEADROOM: 16 KiB per ADR-0105 D6 initial value (1 MiB on Win64 per R3 cycle 6)" {
    const expected: usize = if (builtin.os.tag == .windows) 1024 * 1024 else 16 * 1024;
    try testing.expectEqual(expected, STACK_GUARD_HEADROOM);
}

test "nativeStackHigh: top-of-stack is above the current frame on supported hosts" {
    const high = nativeStackHigh();
    if (high == 0) return; // unsupported / query failed — the scan caller skips
    const sp = @frameAddress();
    // Stack grows down: the top (high) sits above the current frame.
    try testing.expect(high > sp);
    // Sanity: the span from here to the top is a bounded stack, not a
    // wild value (< 1 GiB — typical thread stacks are 512 KiB–8 MiB).
    try testing.expect(high - sp < (1 << 30));
    // And it must sit above `computeStackLimit`'s low-end limit.
    const limit = computeStackLimit(0);
    if (limit != disabled) try testing.expect(high > limit);
}
