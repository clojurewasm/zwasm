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

/// Headroom kept above the actual stack low-end for trap-stub
/// epilogue, signal-handler frame, and recovery state. Per
/// ADR-0105 D6 — initial conservative value; tunable per amend.
pub const STACK_GUARD_HEADROOM: usize = 16 * 1024;

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
// Diagnostic
// ============================================================

/// ADR-0105 R3 diagnostic: once-per-thread stderr report of the
/// JIT-prologue stack-probe context (`stack_limit` value, current
/// approximate SP, margin). Permanent per `.claude/rules/
/// extended_challenge.md` Step 5 — multi-cycle Win64 stack-probe
/// investigations re-use this to confirm the probe sees a sane
/// `rt.stack_limit` BEFORE the recursion crashes the process.
/// One stderr line per thread; safe to leave wired in production
/// (cheap once-flag check + ignored after first call).
threadlocal var diag_seen: bool = false;

pub fn diagOnce(stack_limit_value: usize) void {
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
    std.debug.print(
        "[stack_probe] stack_limit=0x{x} sp=0x{x} margin=0x{x} os={s} arch={s}\n",
        .{ stack_limit_value, sp, margin, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
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

test "STACK_GUARD_HEADROOM: 16 KiB per ADR-0105 D6 initial value" {
    try testing.expectEqual(@as(usize, 16 * 1024), STACK_GUARD_HEADROOM);
}
