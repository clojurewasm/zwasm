//! POSIX signal-context access (ADR-0202 D2): read the faulting PC,
//! WRITE a replacement PC (the fault→trap redirect), and read the
//! fault address from `siginfo_t`.
//!
//! Zig 0.16's std does NOT publicly expose `ucontext_t`/`mcontext_t`
//! (the only definition is the private `signal_ucontext_t` in
//! `std/debug/cpu_context.zig`), so the layouts below mirror that
//! file 1:1 for the four supported host tuples — macOS
//! aarch64/x86_64 (mcontext is a POINTER field) and Linux
//! x86_64/aarch64 (mcontext is EMBEDDED). Unsupported tuples yield
//! null and the caller falls through to the diagnostic path
//! (fail-safe, never a wrong redirect).
//!
//! Zone 0 (`src/platform/`) — depends only on Zig stdlib.

const std = @import("std");
const builtin = @import("builtin");

// Layouts mirrored from std/debug/cpu_context.zig (Zig 0.16). Only
// the fields up to and including what we touch matter; trailing
// state (FP regs etc.) is never read, so it is omitted from the
// EMBEDDED linux structs safely (we only ever hold pointers).

const MacosUcontext = extern struct {
    _onstack: i32,
    _sigmask: std.c.sigset_t,
    _stack: std.c.stack_t,
    _link: ?*MacosUcontext,
    _mcsize: u64,
    mcontext: *MacosMcontext,
};

const MacosMcontext = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
        _far: u64 align(16),
        _esr: u64,
        x: [30]u64,
        lr: u64,
        sp: u64,
        pc: u64,
    },
    .x86_64 => extern struct {
        _trapno: u16,
        _cpu: u16,
        _err: u32,
        _faultvaddr: u64,
        rax: u64,
        rbx: u64,
        rcx: u64,
        rdx: u64,
        rdi: u64,
        rsi: u64,
        rbp: u64,
        rsp: u64,
        r8: u64,
        r9: u64,
        r10: u64,
        r11: u64,
        r12: u64,
        r13: u64,
        r14: u64,
        r15: u64,
        rip: u64,
    },
    else => extern struct { _unsupported: u64 },
};

const LinuxUcontextAarch64 = extern struct {
    _flags: usize,
    _link: ?*LinuxUcontextAarch64,
    _stack: std.os.linux.stack_t,
    _sigmask: std.os.linux.sigset_t,
    _unused: [120]u8,
    mcontext: extern struct {
        _fault_address: u64 align(16),
        x: [30]u64,
        lr: u64,
        sp: u64,
        pc: u64,
    },
};

const LinuxUcontextX8664 = extern struct {
    _flags: usize,
    _link: ?*LinuxUcontextX8664,
    _stack: std.os.linux.stack_t,
    mcontext: extern struct {
        r8: u64,
        r9: u64,
        r10: u64,
        r11: u64,
        r12: u64,
        r13: u64,
        r14: u64,
        r15: u64,
        rdi: u64,
        rsi: u64,
        rbp: u64,
        rbx: u64,
        rdx: u64,
        rax: u64,
        rcx: u64,
        rsp: u64,
        rip: u64,
    },
};

/// Pointer to the mutable PC slot inside the signal ucontext, or null
/// when the host tuple has no supported layout (caller falls through
/// to the diagnostic disposition). Reading yields the faulting PC;
/// writing redirects the resume point (the kernel's sigreturn
/// restores the modified context).
pub fn pcPtr(uctx: ?*anyopaque) ?*u64 {
    const ctx = uctx orelse return null;
    if (comptime builtin.os.tag == .macos and
        (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64))
    {
        const uc: *MacosUcontext = @ptrCast(@alignCast(ctx));
        return switch (comptime builtin.cpu.arch) {
            .aarch64 => &uc.mcontext.pc,
            .x86_64 => &uc.mcontext.rip,
            else => unreachable,
        };
    }
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
        const uc: *LinuxUcontextAarch64 = @ptrCast(@alignCast(ctx));
        return &uc.mcontext.pc;
    }
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        const uc: *LinuxUcontextX8664 = @ptrCast(@alignCast(ctx));
        return &uc.mcontext.rip;
    }
    return null;
}

/// The faulting data address from `siginfo_t` (SIGSEGV/SIGBUS).
pub fn faultAddr(info: *const std.posix.siginfo_t) usize {
    if (comptime builtin.os.tag == .macos) {
        return @intFromPtr(info.addr);
    }
    if (comptime builtin.os.tag == .linux) {
        return @intFromPtr(info.fields.sigfault.addr);
    }
    return 0;
}
