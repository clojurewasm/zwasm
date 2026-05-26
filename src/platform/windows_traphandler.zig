//! Win64 trap-recovery bridge via AddVectoredExceptionHandler +
//! threadlocal RecoveryInfo (ADR-0103).
//!
//! POSIX-equivalent contract: `arm(info)` + `disarm()` map to
//! `sigsetjmp` / `siglongjmp` semantics for Windows-target JIT
//! callers. On a hardware fault inside `[info.jit_code_start,
//! info.jit_code_end)`, the VEH callback rewrites the trapping
//! thread's `Rip` / `Rsp` / `Rax` so execution resumes at
//! `recovery_pc` with `recovery_rax_trap_code` in `RAX`.
//!
//! Mac / ubuntu builds compile this file but every public entry
//! point is a no-op there; the POSIX SIGSEGV handler still owns
//! recovery on those targets. See `test/spec/spec_assert_
//! runner_base.zig::installSigsegvHandler` for the comptime arm.
//!
//! Zone 0 (`src/platform/`). Pure Zig; the Win32 entry points
//! come from `std.os.windows.ntdll`, so no fresh `@extern` is
//! introduced here (libc_boundary.md does not fire).

const builtin = @import("builtin");
const std = @import("std");

/// Per-call recovery state. Filled in by `arm()` immediately
/// before the JIT body is invoked; consumed by `vehHandler` on
/// a matching fault.
pub const RecoveryInfo = struct {
    /// Inclusive lower bound of the JIT-emitted code region the
    /// recovery applies to. Faults outside `[start, end)` pass
    /// through to the next handler.
    jit_code_start: usize,
    /// Exclusive upper bound.
    jit_code_end: usize,
    /// Resume-point program counter (the caller's recovery label).
    recovery_pc: usize,
    /// Resume-point stack pointer (Win64 ABI invariants assumed
    /// to hold at this SP).
    recovery_sp: usize,
    /// Value loaded into RAX on resume — the trap code the runner
    /// observes via its `Error.Trap`-coded return value.
    recovery_rax_trap_code: u64,
};

const ActiveRecovery = struct {
    info: RecoveryInfo,
    active: bool,
};

threadlocal var recovery: ActiveRecovery = .{
    .info = .{
        .jit_code_start = 0,
        .jit_code_end = 0,
        .recovery_pc = 0,
        .recovery_sp = 0,
        .recovery_rax_trap_code = 0,
    },
    .active = false,
};

/// Install the VEH callback. Idempotent — safe to call multiple
/// times; the second call is a no-op. No-op on non-Windows
/// targets.
pub fn install() void {
    if (comptime builtin.os.tag != .windows) return;
    impl.install();
}

/// Remove the VEH callback. Safe to call when not installed.
/// No-op on non-Windows targets.
pub fn uninstall() void {
    if (comptime builtin.os.tag != .windows) return;
    impl.uninstall();
}

/// Arm the threadlocal recovery context. `disarm()` MUST be
/// called on every exit path (success or failure) — pair via
/// `defer` at the callsite. No-op on non-Windows.
pub fn arm(info: RecoveryInfo) void {
    if (comptime builtin.os.tag != .windows) return;
    recovery.info = info;
    @atomicStore(bool, &recovery.active, true, .release);
}

/// Clear the threadlocal recovery context. No-op on non-Windows.
pub fn disarm() void {
    if (comptime builtin.os.tag != .windows) return;
    @atomicStore(bool, &recovery.active, false, .release);
}

/// Run `jit_fn(args)` under VEH protection on Windows. Returns
/// `true` if `jit_fn` either (a) trapped via a hardware fault
/// inside `[jit_code_start, jit_code_end)` (VEH redirected to
/// the function's return point with `Rax = 1`), or (b) returned
/// `error.Trap` from the entry shim. Returns `false` on clean
/// success.
///
/// **Must NOT be inlined** — `@returnAddress()` must point at
/// the caller's RIP after this function returns, and inline asm
/// captures the helper's frame RSP. Marked `noinline` per
/// ADR-0103 Consequences refinement.
///
/// POSIX path: callers gate via `if (comptime builtin.os.tag ==
/// .windows) ...` and keep the existing `sigsetjmp` site inline
/// in the caller frame (per discipline at
/// `spec_assert_runner_base.zig:2306-2312`).
pub noinline fn callJitOrTrap(
    jit_code_start: usize,
    jit_code_end: usize,
    comptime jit_fn: anytype,
    args: anytype,
) bool {
    if (comptime builtin.os.tag != .windows) return false;
    var rsp_on_entry: usize = undefined;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("mov %%rsp, %[sp]"
            : [sp] "=r" (rsp_on_entry),
            :
            : .{ .memory = true });
    }
    arm(.{
        .jit_code_start = jit_code_start,
        .jit_code_end = jit_code_end,
        .recovery_pc = @returnAddress(),
        .recovery_sp = rsp_on_entry + 8,
        .recovery_rax_trap_code = 1,
    });
    defer disarm();
    @call(.never_inline, jit_fn, args) catch |err| switch (err) {
        error.Trap => return true,
    };
    return false;
}

const impl = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;

    // Not exported by std.os.windows; declared per MSDN
    // (errhandlingapi.h / winnt.h).
    const EXCEPTION_CONTINUE_EXECUTION: c_long = -1;
    const EXCEPTION_INT_DIVIDE_BY_ZERO: u32 = 0xC0000094;
    const EXCEPTION_INT_OVERFLOW: u32 = 0xC0000095;

    var veh_handle: ?win.PVOID = null;

    fn vehHandler(exception_info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        if (!@atomicLoad(bool, &recovery.active, .acquire)) {
            return win.EXCEPTION_CONTINUE_SEARCH;
        }
        const code = exception_info.ExceptionRecord.ExceptionCode;
        switch (code) {
            win.EXCEPTION_ACCESS_VIOLATION,
            win.EXCEPTION_ILLEGAL_INSTRUCTION,
            EXCEPTION_INT_DIVIDE_BY_ZERO,
            EXCEPTION_INT_OVERFLOW,
            => {},
            else => return win.EXCEPTION_CONTINUE_SEARCH,
        }
        // ADR-0105 D4 (2026-05-23): EXCEPTION_STACK_OVERFLOW removed
        // from the filter. The JIT-prologue stack-probe (ADR-0105 D2)
        // traps cleanly via the kind=4 stack-overflow trap stub
        // BEFORE SP descends past the guard page — VEH no longer
        // sees this exception code. Removing the arm dissolves the
        // guard-page-restoration headache (`_resetstkoflw()` etc.).
        const rip = exception_info.ContextRecord.Rip;
        if (rip < recovery.info.jit_code_start or rip >= recovery.info.jit_code_end) {
            return win.EXCEPTION_CONTINUE_SEARCH;
        }
        // Redirect the trapping thread to the recovery label.
        exception_info.ContextRecord.Rip = recovery.info.recovery_pc;
        exception_info.ContextRecord.Rsp = recovery.info.recovery_sp;
        exception_info.ContextRecord.Rax = recovery.info.recovery_rax_trap_code;
        // One-shot: clear the armed flag so a subsequent fault
        // outside an `arm()`-guarded region surfaces normally.
        @atomicStore(bool, &recovery.active, false, .release);
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    fn install() void {
        if (veh_handle != null) return;
        // First = 0 places the handler at the back of the VEH
        // chain — pre-existing host handlers run first. Per
        // ADR-0103 Negative consequence mitigation.
        veh_handle = win.ntdll.RtlAddVectoredExceptionHandler(0, &vehHandler);
    }

    fn uninstall() void {
        if (veh_handle) |h| {
            _ = win.ntdll.RtlRemoveVectoredExceptionHandler(h);
            veh_handle = null;
        }
    }
} else struct {};

// -----------------------------------------------------------
// Tests — exercised on Mac / ubuntu (POSIX no-op path).
// windowsmini verifies the Windows-active branch at W4 reconcile.
// -----------------------------------------------------------

test "RecoveryInfo struct shape" {
    const info: RecoveryInfo = .{
        .jit_code_start = 0x1000,
        .jit_code_end = 0x2000,
        .recovery_pc = 0x3000,
        .recovery_sp = 0x4000,
        .recovery_rax_trap_code = 7,
    };
    try std.testing.expectEqual(@as(usize, 0x1000), info.jit_code_start);
    try std.testing.expectEqual(@as(usize, 0x2000), info.jit_code_end);
    try std.testing.expectEqual(@as(u64, 7), info.recovery_rax_trap_code);
}

test "install/uninstall non-Windows no-op" {
    // SIBLING-AT: src/platform/windows_traphandler.zig:62 (install impl)
    // — POSIX no-op path; Windows VEH path verified by W4 reconcile.
    if (comptime builtin.os.tag == .windows) return;
    install();
    uninstall();
    // Reaching here = no crash; install/uninstall returned cleanly.
}

test "arm/disarm non-Windows no-op leaves threadlocal untouched" {
    // SIBLING-AT: src/platform/windows_traphandler.zig:62 (install impl)
    // — POSIX no-op path; Windows VEH path verified by W4 reconcile.
    if (comptime builtin.os.tag == .windows) return;
    arm(.{
        .jit_code_start = 0xDEADBEEF,
        .jit_code_end = 0xFEEDFACE,
        .recovery_pc = 0,
        .recovery_sp = 0,
        .recovery_rax_trap_code = 0,
    });
    // arm() is a no-op on POSIX; the threadlocal must remain at
    // its initialiser state (active=false). Verified via the
    // private API surface to ensure the comptime gate fires.
    try std.testing.expect(!@atomicLoad(bool, &recovery.active, .acquire));
    disarm();
    try std.testing.expect(!@atomicLoad(bool, &recovery.active, .acquire));
}
