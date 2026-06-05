//! Production internal-fault handler (ADR-0166, D-292 B-core).
//!
//! v2 uses NO signal-based wasm trap semantics — every wasm trap is an explicit
//! check surfacing as `Error.Trap` (CLI exit 1 + a `trap kind=…` line). So ANY
//! fatal signal that reaches the OS is a zwasm-INTERNAL bug, never normal
//! operation. `installInternalFaultHandler` (called once from `cli/main.zig`)
//! installs a diagnostic-only, last-resort handler: on an unintended
//! SIGSEGV/SIGBUS/SIGILL/SIGFPE it writes a fixed "internal error" line
//! (async-signal-safe) and `_exit`s with a DISTINCT code, instead of a silent
//! signal-death — so the fault is diagnosable and clearly NOT a wasm trap.
//!
//! Diagnostic-only: it always EXITS, never resumes (no recovery, unlike the
//! test runner's `spec_assert_runner_base.installSigsegvHandler` which
//! siglongjmps for JIT-trap recovery). Windows lands in ADR-0166 cycle II.
//!
//! Zone 0 (`src/platform/`).

const builtin = @import("builtin");
const std = @import("std");
const skip = @import("../test_support/skip.zig");

/// EX_SOFTWARE (sysexits.h) — "an internal software error". Distinct from CLI
/// exit 1 (a clean wasm trap) and from a signal-default death (128+signo), so
/// the three outcomes are unambiguous to a caller / CI.
pub const INTERNAL_ERROR_EXIT_CODE: u8 = 70;

const enabled = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// Async-signal-safe raw write(2) — POSIX signal-safety(7). The `std.posix.write`
/// wrapper returns an error union (forcing a fallback in a signal context); the
/// raw libc primitive is the canonical async-signal-safe write. ADR-0070
/// necessary (production signal-handler site; same rationale as `_exit`).
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

// Page-aligned alternate signal stack so a stack-overflow SIGSEGV (host-side deep
// native recursion, cf. D-288) can still run the handler on a fresh stack.
const ALT_STACK_SIZE: usize = 1 << 16; // 64 KiB
var alt_stack: [ALT_STACK_SIZE]u8 align(std.heap.page_size_max) = undefined;

const INTERNAL_ERROR_MSG =
    "zwasm: internal error — caught a fatal signal. This is a bug in zwasm " ++
    "(not a wasm trap); please report it.\n";

fn faultHandler(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // Async-signal-safe only: raw write(2) + `_exit` (skips atexit/stdio). No
    // allocation, no formatting, no recovery — always exits.
    _ = write(2, INTERNAL_ERROR_MSG, INTERNAL_ERROR_MSG.len);
    std.c._exit(INTERNAL_ERROR_EXIT_CODE);
}

// Windows (ADR-0166 cycle II): a production diagnostic-only vectored-exception
// handler. Mirrors `windows_traphandler`'s API surface (ntdll VEH, no fresh
// @extern), but — unlike that JIT-trap-RECOVERY VEH — this one is the last-resort
// disposition: on a genuine fault it writes the "internal error" line and
// `ExitProcess(70)` (never returns), instead of resuming. Production-only (NOT
// the test harness), so it never shadows the recovery VEH (which production
// never arms anyway).
const win_impl = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;
    var veh_handle: ?win.PVOID = null;

    // Zig 0.16's std.os.windows does not expose these kernel32 entry points;
    // declare them per MSDN (mirrors windows_traphandler's MSDN constant decls).
    // kernel32 is the Windows system library, not libc (ADR-0070 does not fire).
    extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nBytes: win.DWORD, lpWritten: ?*win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
    extern "kernel32" fn ExitProcess(uExitCode: win.UINT) callconv(.winapi) noreturn;
    const STD_ERROR_HANDLE: win.DWORD = @bitCast(@as(i32, -12)); // MSDN

    fn handler(exception_info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        const code = exception_info.ExceptionRecord.ExceptionCode;
        switch (code) {
            win.EXCEPTION_ACCESS_VIOLATION,
            win.EXCEPTION_ILLEGAL_INSTRUCTION,
            win.EXCEPTION_DATATYPE_MISALIGNMENT,
            => {
                const h = GetStdHandle(STD_ERROR_HANDLE);
                var written: win.DWORD = 0;
                _ = WriteFile(h, INTERNAL_ERROR_MSG.ptr, @intCast(INTERNAL_ERROR_MSG.len), &written, null);
                ExitProcess(INTERNAL_ERROR_EXIT_CODE);
            },
            // Faults v2 doesn't own (e.g. a host-installed handler's) pass through.
            else => return win.EXCEPTION_CONTINUE_SEARCH,
        }
    }

    fn install() void {
        if (veh_handle != null) return;
        // First = 1 → FRONT of the VEH chain. Registered in main() AFTER Zig's
        // runtime attaches its own (Debug-mode) segfault VEH, so the most-recently-
        // registered First=1 handler — ours — is called first. Without this, Zig's
        // default handler intercepts the fault (prints a trace + exits 3) and ours
        // never runs (it caught exit 3, not our 70, on the test-internal-fault gate).
        // Production-only install → never shadows the (never-armed) JIT-recovery VEH.
        veh_handle = win.ntdll.RtlAddVectoredExceptionHandler(1, &handler);
    }
} else struct {};

/// Install the diagnostic-only internal-fault handler. Call once at CLI startup
/// (production entry). No-op on wasi. NOT installed by the test harness — the spec
/// runners own their own (recovery) handler; this is the production last-resort
/// disposition.
pub fn installInternalFaultHandler() void {
    if (comptime builtin.os.tag == .windows) {
        win_impl.install();
        return;
    }
    if (comptime !enabled) return;
    std.posix.sigaltstack(&.{
        .sp = &alt_stack,
        .flags = 0,
        .size = alt_stack.len,
    }, null) catch |err| {
        // Non-fatal: the handler still works without an altstack for the common
        // (non-stack-overflow) fault. Surface it; do NOT abort startup.
        std.debug.print("zwasm: warning: sigaltstack failed ({s}); fault handler degraded\n", .{@errorName(err)});
    };
    var act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = faultHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.ONSTACK | std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(.SEGV, &act, null);
    std.posix.sigaction(.BUS, &act, null);
    std.posix.sigaction(.ILL, &act, null);
    std.posix.sigaction(.FPE, &act, null);
}

test "installInternalFaultHandler: a fault in a forked child exits 70 (handler ran), not a signal-death" {
    // Windows handler = ADR-0166 cycle II; comptime gate also prunes the POSIX
    // fork tail (std.c.fork is not declared on Windows) — mirrors the realworld
    // runner's `if (comptime !use_fork)` pattern.
    if (comptime !enabled) return skip.phaseEnd(.win64);
    // fork the test process: the child installs the handler + deliberately
    // faults; the parent verifies the child EXITED with code 70 (the handler
    // ran + _exit'd cleanly) rather than being killed by the signal (which would
    // be WIFSIGNALED). std.c.fork/waitpid = ADR-0070 necessary (test-only).
    const pid = std.c.fork();
    try std.testing.expect(pid != -1); // fork must succeed on a POSIX test host
    if (pid == 0) {
        installInternalFaultHandler();
        const p: *allowzero volatile u8 = @ptrFromInt(0); // null page → SIGSEGV
        p.* = 0;
        std.c._exit(1); // unreachable if the handler fired
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    try std.testing.expect(std.posix.W.IFEXITED(ustatus));
    try std.testing.expectEqual(@as(u32, INTERNAL_ERROR_EXIT_CODE), std.posix.W.EXITSTATUS(ustatus));
}
