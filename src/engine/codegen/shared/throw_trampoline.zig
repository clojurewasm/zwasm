//! `zwasm_throw` assembly entry glue (ADR-0114 D6 + ADR-0119).
//!
//! Per-arch `callconv(.naked)` trampoline invoked by JIT-emitted
//! `throw` / `throw_ref` sites. The naked attribute (ADR-0119) is
//! load-bearing — Zig MUST NOT emit a prologue/epilogue here, so
//! the trampoline observes the caller's FP (X29 / RBP) and saved
//! LR/RIP intact at entry.
//!
//! ## Current shape (IT-6 cycle 3a)
//!
//! The trampoline body is currently the minimal **trap-only**
//! shape: set `JitRuntime.trap_flag = 1`, set `X0 / RAX = 0`, and
//! RET to the caller. The dispatchThrow integration (full FP-walk
//! + handler-vs-uncaught branch per ADR-0114 D6 step 4-5) lands in
//! the follow-on cycle; this commit establishes the symbol +
//! file scaffolding so `op_throw.emit` can be retargeted from
//! its IT-3 "B-to-trap-stub" shape to "CALL trampoline".
//!
//! Per ADR-0017, X19 (arm64) / R15 (x86_64) hold the pinned
//! `*JitRuntime` across every JIT call boundary. Naked attr +
//! the AAPCS64 / SysV / Win64 callee-saved discipline mean the
//! trampoline inherits the pinned value from the throwing
//! function — no separate load needed.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const builtin = @import("builtin");

const jit_abi = @import("jit_abi.zig");

// ADR-0119 §Removal condition #1 — empirically validated 2026-05-27
// (spike `private/spikes/p10-it6-naked-trampoline/`): Zig 0.16
// `callconv(.naked)` produces zero prologue + epilogue on all three
// supported hosts (aarch64-macos / x86_64-linux-gnu /
// x86_64-windows-gnu).

// Clobber sets: the trampoline body uses caller-saved scratch only
// (X17 / R10), so the standard "memory" clobber suffices for the
// trap_flag store visibility.
const arm64_clobbers = if (builtin.target.cpu.arch == .aarch64)
    std.builtin.assembly.Clobbers{ .memory = true }
else {
    // non-aarch64 hosts skip the arm64 branch; void collapses.
};

const x86_64_clobbers = if (builtin.target.cpu.arch == .x86_64)
    std.builtin.assembly.Clobbers{ .memory = true }
else {
    // non-x86_64 hosts skip the x86_64 branch; void collapses.
};

/// trap_flag byte offset within `JitRuntime` — same value the
/// per-arch trap stubs use (per ADR-0017 + jit_abi). Read at
/// comptime so the trampoline body inlines the literal.
const trap_flag_off: u32 = jit_abi.trap_flag_off;

/// EH dispatcher trampoline. Invoked via BL/CALL from JIT-emitted
/// `throw` / `throw_ref` sites; expects the pinned JitRuntime ptr
/// in X19 (arm64) / R15 (x86_64) per ADR-0017.
///
/// Body shape (IT-6 cycle 3a — trap-only):
///   1. Load `W17 = 1` (arm64) / `R10D = 1` (x86_64).
///   2. Store W17/R10D into `[X19/R15 + trap_flag_off]`.
///   3. Zero X0 / RAX (entry-shim return convention).
///   4. RET to caller (the throwing JIT function's post-CALL pc).
///
/// The caller falls into its function-end trap-stub branch
/// (existing bounds_fixups / unreach_fixups path), which then
/// runs the standard epilogue and returns to the entry shim.
pub fn zwasmThrowTrampoline() callconv(.naked) noreturn {
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
        // MOVZ W17, #1   ; trap indicator
            \\ movz w17, #1
            // STR W17, [X19, #trap_flag_off]
            \\ str w17, [x19, %[off]]
            // MOV X0, #0     ; clear return value
            \\ movz x0, #0
            // RET            ; back to the JIT throw site's post-BL pc
            \\ ret
            :
            : [off] "i" (trap_flag_off),
            : arm64_clobbers),
        .x86_64 => asm volatile (
        // mov $1, %r10d
            \\ movl $1, %%r10d
            // mov %r10d, trap_flag_off(%r15)
            \\ movl %%r10d, %c[off](%%r15)
            // xor %eax, %eax  ; clear return value
            \\ xorl %%eax, %%eax
            \\ retq
            :
            : [off] "i" (trap_flag_off),
            : x86_64_clobbers),
        else => @compileError("unsupported host arch for EH trampoline"),
    }
}

// ---------------------------------------------------------------------
// Tests — invoke the trampoline via an inline-asm wrapper that loads
// the pinned register (X19/R15) with a mock JitRuntime, BL/CALLs the
// trampoline, and verifies trap_flag was set.
// ---------------------------------------------------------------------

const testing = std.testing;

/// Wrapper that sets up the pinned `*JitRuntime` register and calls
/// the trampoline. Uses the same inline-asm pattern as entry.zig's
/// `aarch64_blr_clobbers` Class B thunks. The wrapper itself runs
/// a normal Zig prologue/epilogue; only the inner BL/CALL targets
/// the naked trampoline.
fn invokeTrampolineWith(rt: *jit_abi.JitRuntime) void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            // Save the caller's X19 (per AAPCS64 callee-saved), load
            // the test's mock RT into X19, BL the trampoline, restore X19.
            const trampoline_addr: usize = @intFromPtr(&zwasmThrowTrampoline);
            asm volatile (
                \\ mov x10, x19
                \\ mov x19, %[rt]
                \\ blr %[addr]
                \\ mov x19, x10
                :
                : [rt] "r" (rt),
                  [addr] "r" (trampoline_addr),
                : aarch64_invoke_clobbers);
        },
        .x86_64 => {
            const trampoline_addr: usize = @intFromPtr(&zwasmThrowTrampoline);
            asm volatile (
                \\ movq %%r15, %%r12
                \\ movq %[rt], %%r15
                \\ callq *%[addr]
                \\ movq %%r12, %%r15
                :
                : [rt] "r" (rt),
                  [addr] "r" (trampoline_addr),
                : x86_64_invoke_clobbers);
        },
        else => @compileError("unsupported host arch"),
    }
}

const aarch64_invoke_clobbers = if (builtin.target.cpu.arch == .aarch64)
    std.builtin.assembly.Clobbers{
        .x0 = true,
        .x10 = true,
        .x17 = true,
        .x30 = true,
        .memory = true,
    }
else {
    // non-aarch64 hosts skip.
};

const x86_64_invoke_clobbers = if (builtin.target.cpu.arch == .x86_64)
    std.builtin.assembly.Clobbers{
        .rax = true,
        .r10 = true,
        .r12 = true,
        .memory = true,
    }
else {
    // non-x86_64 hosts skip.
};

test "zwasmThrowTrampoline: sets trap_flag=1 via pinned runtime-ptr" {
    var rt: jit_abi.JitRuntime = std.mem.zeroes(jit_abi.JitRuntime);
    try testing.expectEqual(@as(u32, 0), rt.trap_flag);
    invokeTrampolineWith(&rt);
    try testing.expectEqual(@as(u32, 1), rt.trap_flag);
}

test "zwasmThrowTrampoline: symbol address is non-zero (linker exported)" {
    try testing.expect(@intFromPtr(&zwasmThrowTrampoline) != 0);
}
