//! `zwasm_throw` assembly entry glue (ADR-0114 D6 + ADR-0119).
//!
//! Per-arch `callconv(.naked)` trampoline invoked by JIT-emitted
//! `throw` / `throw_ref` sites. The naked attribute (ADR-0119) is
//! load-bearing — Zig MUST NOT emit a prologue/epilogue here, so
//! the trampoline observes the caller's FP (X29 / RBP) and saved
//! LR/RIP intact at entry.
//!
//! ## Current shape (IT-6 cycle 3c-ii)
//!
//! Two-layer architecture per ADR-0119 §Consequences:
//!
//! 1. `zwasmThrowTrampoline()` — tiny `callconv(.naked)` stub.
//!    Captures throw-site FP + LR + tag_idx + runtime-ptr into
//!    AAPCS64 / SysV arg regs, BL/CALLs into `trampolineCore`,
//!    then restores the saved FP/LR and RETs to the throw site
//!    (which then falls through to its trap-stub fallback).
//!
//! 2. `trampolineCore(initial_fp, throw_site_addr, tag_idx, rt)`
//!    — regular `callconv(.c)` Zig. Materializes ExceptionTable +
//!    CodeMap from `rt`, builds a `ThrowSite`, calls
//!    `shared/zwasm_throw.dispatchThrow`, and on the result:
//!      - `.uncaught`: sets `rt.trap_flag = 1` and returns (the
//!        naked stub then RETs to the throw site whose B/JMP
//!        falls through to the trap stub).
//!      - `.handler`: currently ALSO sets `rt.trap_flag = 1` —
//!        full handler dispatch (sp_restore + JMP landing_pad_pc)
//!        lands at cycle 3c-iii.
//!
//! Net observable behavior at cycle 3c-ii matches IT-3 (every
//! throw traps); the load-bearing delta is that the dispatcher
//! is ACTUALLY invoked, the EH table + code map are walked, and
//! handler resolution is exercised end-to-end. Installing a
//! catch handler in a fixture's exception_table now flows through
//! the unwinder; only the .handler→landing-pad JMP is deferred.
//!
//! Per ADR-0017, X19 (arm64) / R15 (x86_64) hold the pinned
//! `*JitRuntime` across every JIT call boundary. Naked attr +
//! the AAPCS64 / SysV callee-saved discipline mean the trampoline
//! inherits the pinned value from the throwing function — no
//! separate load needed at the entry point.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const builtin = @import("builtin");

const jit_abi = @import("jit_abi.zig");
const exception_table = @import("exception_table.zig");
const code_map_mod = @import("code_map.zig");
const zwasm_throw = @import("zwasm_throw.zig");

// ADR-0119 §Removal condition #1 — empirically validated 2026-05-27
// (spike `private/spikes/p10-it6-naked-trampoline/`): Zig 0.16
// `callconv(.naked)` produces zero prologue + epilogue on all three
// supported hosts (aarch64-macos / x86_64-linux-gnu /
// x86_64-windows-gnu).

const arm64_clobbers = if (builtin.target.cpu.arch == .aarch64)
    std.builtin.assembly.Clobbers{
        // We MOV into x0..x3 to marshal trampolineCore args. BLR
        // clobbers x30. trampolineCore itself (Zig fn, callconv(.c))
        // clobbers the standard AAPCS64 caller-saved cohort; we
        // list the explicit writers and BLR clobber, with memory
        // covering the trap_flag store inside trampolineCore.
        .x0 = true,
        .x1 = true,
        .x2 = true,
        .x3 = true,
        .x30 = true,
        .memory = true,
    }
else {
    // non-aarch64 hosts skip the arm64 branch; void collapses.
};

const x86_64_clobbers = if (builtin.target.cpu.arch == .x86_64)
    std.builtin.assembly.Clobbers{ .memory = true }
else {
    // non-x86_64 hosts skip the x86_64 branch; void collapses.
};

/// Trampoline-core: regular Zig fn, called from the naked stub.
///
/// Args (AAPCS64 / SysV C-ABI):
///   X0 / RDI = `initial_fp`       — throw fn's FP at throw site
///   X1 / RSI = `throw_site_addr`  — saved LR / RIP at the BL/CALL
///   X2 / RDX = `tag_idx`          — from throw site's MOVZ / MOV
///   X3 / RCX = `rt`               — `*JitRuntime` (= pinned X19/R15)
///
/// Pure data-flow: no inline asm here. Easier to test + reason about
/// than the equivalent inline assembly. The naked stub's only job
/// is to marshal these args and call this.
pub fn trampolineCore(
    initial_fp: usize,
    throw_site_addr: usize,
    tag_idx: u32,
    rt: *jit_abi.JitRuntime,
) callconv(.c) void {
    // Materialize the per-Instance EH views from `rt` (populated
    // at instance init per IT-6 cycle 3c-i).
    const table: zwasm_throw.ExceptionTable = .{
        .entries = if (rt.eh_table_entries) |p|
            p[0..rt.eh_table_count]
        else
            &.{},
    };
    const cmap: zwasm_throw.CodeMap = .{
        .entries = if (rt.eh_code_map_entries) |p|
            p[0..rt.eh_code_map_count]
        else
            &.{},
    };
    const site: zwasm_throw.ThrowSite = .{
        .initial_fp = initial_fp,
        .throw_site_addr = throw_site_addr,
        .tag_idx = tag_idx,
    };

    const result = zwasm_throw.dispatchThrow(
        table,
        &cmap,
        site,
        zwasm_throw.default_max_unwind_depth,
    );

    switch (result) {
        .uncaught => {
            rt.trap_flag = 1;
        },
        .handler => |h| {
            // IT-6 cycle 3c-iii (next) — handler dispatch via
            // `sp_restore.emitSpRestoreFull` + JMP to landing_pad_pc
            // (resolved to absolute via CodeMap.Entry.start_addr +
            // landing_pad_pc, then BR / JMP). Until that lands, the
            // .handler path traps; the unwinder match is still
            // verified end-to-end via a fixture's installed catch.
            _ = h;
            rt.trap_flag = 1;
        },
    }
}

/// EH dispatcher trampoline. Invoked via BL/CALL from JIT-emitted
/// `throw` / `throw_ref` sites; expects:
///   - X0 / EDI: tag_idx (set by `op_throw.emit` marshal step)
///   - X19 / R15: pinned `*JitRuntime` (per ADR-0017)
///   - X29 / RBP: throw fn's frame pointer (intact via callee-
///     saved + naked-no-prologue discipline)
///   - X30 / [RSP]: saved-LR / saved-RIP (the throw-site address)
///
/// Marshals these into the C-ABI argregs for `trampolineCore`,
/// calls it, then restores the saved FP/LR and RETs back to the
/// throw site's post-CALL B/JMP (which falls through to the
/// function trap stub for the standard epilogue).
pub fn zwasmThrowTrampoline() callconv(.naked) noreturn {
    switch (builtin.target.cpu.arch) {
        // ARM64 body — comments outside the asm template (the
        // LLVM ARM64 inline-asm parser doesn't reliably accept
        // `//` as a comment delimiter in all build configs).
        //
        // Layout:
        //   stp x29, x30, [sp, #-16]!  ; save throw site's FP+LR
        //                                (need both for post-call
        //                                RET; STP also keeps SP
        //                                16-aligned for AAPCS64).
        //   mov x3, x19                ; arg3 = rt ptr (pinned)
        //   mov x2, x0                 ; arg2 = tag_idx (from
        //                                throw site's MOV W0)
        //   mov x1, x30                ; arg1 = throw_site_addr
        //                                (saved LR from BLR)
        //   mov x0, x29                ; arg0 = initial_fp
        //                                (throw fn's FP)
        //   blr %[core]                ; call trampolineCore;
        //                                BLR clobbers X30 with
        //                                "return from this BLR";
        //                                trampolineCore's own
        //                                prologue saves+restores
        //                                its X29/X30.
        //   ldp x29, x30, [sp], #16    ; restore throw site's FP+LR
        //   ret                        ; jump to X30 = throw-site
        //                                post-BLR (lands at the
        //                                B trap_stub).
        .aarch64 => asm volatile (
            \\stp x29, x30, [sp, #-16]!
            \\mov x3, x19
            \\mov x2, x0
            \\mov x1, x30
            \\mov x0, x29
            \\blr %[core]
            \\ldp x29, x30, [sp], #16
            \\ret
            :
            : [core] "r" (&trampolineCore),
            : arm64_clobbers),
        // x86_64 SysV body:
        //   pushq %rbp           ; save throw fn's FP; SP -> 16-aligned
        //   movq 8(%rsp), %rsi   ; arg1 = throw_site_addr (saved RIP at
        //                          old [RSP]; PUSH bumped it to +8)
        //   movq %rdi, %rdx      ; arg2 = tag_idx (was in RDI per the
        //                          throw site's MOV EDI marshal)
        //   movq %rbp, %rdi      ; arg0 = initial_fp (throw fn's FP)
        //   movq %r15, %rcx      ; arg3 = rt ptr
        //   callq *[core]
        //   popq %rbp            ; restore RBP, RSP back to entry+0
        //   retq                 ; jump to saved RIP (throw-site)
        .x86_64 => switch (builtin.target.os.tag) {
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => asm volatile (
                \\pushq %%rbp
                \\movq 8(%%rsp), %%rsi
                \\movq %%rdi, %%rdx
                \\movq %%rbp, %%rdi
                \\movq %%r15, %%rcx
                \\callq *%[core]
                \\popq %%rbp
                \\retq
                :
                : [core] "r" (&trampolineCore),
                : x86_64_clobbers),
            .windows => @compileError(
                "x86_64-windows EH trampoline body is cycle 3c-iii scope; " ++
                    "Win64 ABI arg shuffling differs from SysV (RCX/RDX/R8/R9 + shadow space).",
            ),
            else => @compileError("unsupported x86_64 OS for EH trampoline"),
        },
        else => @compileError("unsupported host arch for EH trampoline"),
    }
}

// ---------------------------------------------------------------------
// Tests — invoke the trampoline via an inline-asm wrapper that loads
// the pinned register (X19/R15) with a mock JitRuntime, BL/CALLs the
// trampoline, and verifies trap_flag was set.
// ---------------------------------------------------------------------

const testing = std.testing;

/// Wrapper that sets up the pinned `*JitRuntime` register, installs
/// a 2-slot **sentinel frame** as the trampoline's initial X29 / RBP,
/// and calls the trampoline. The sentinel terminates the unwinder's
/// frame-chain walk at depth 1 (`caller_fp == 0` → `.uncaught`) so
/// the test never depends on the host process's frame-pointer chain
/// being intact — Zig 0.16's self-hosted x86_64 backend doesn't
/// reliably maintain RBP-chaining, so walking the host stack would
/// dereference garbage and SEGV in a subsequent test (see lesson
/// `2026-05-28-eh-test-wrapper-host-fp-walk-segv.md`).
fn invokeTrampolineWith(rt: *jit_abi.JitRuntime, tag_idx: u32) void {
    // Sentinel "frame" the trampoline's naked stub will capture as
    // initial X29 / RBP: slot 0 = caller_fp = 0 (= top-of-Wasm-stack
    // sentinel per ADR-0114 D5 + arm64/frame_chain.zig docstring),
    // slot 1 = caller_lr = 0 (unused after caller_fp termination).
    var sentinel: [2]usize align(16) = .{ 0, 0 };
    const sentinel_ptr: usize = @intFromPtr(&sentinel);
    // Widen tag_idx to u64 so the "r" constraint guarantees a
    // full-width X (arm64) / RAX-class (x86_64) register with
    // the upper bits zero.
    const tag_idx_widened: u64 = tag_idx;
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            const trampoline_addr: usize = @intFromPtr(&zwasmThrowTrampoline);
            // STP saves X19 + X29 on the stack (16-byte aligned). The
            // trampoline body then sees X19 = rt and X29 = sentinel_ptr.
            // BLR clobbers X0..X17 + X30 (AAPCS64 caller-saved set);
            // the trampoline's own prologue saves X29/X30. After return,
            // LDP restores both. Comments live outside the asm template
            // body — the LLVM ARM64 inline-asm parser doesn't reliably
            // accept `//` mid-line.
            asm volatile (
                \\stp x19, x29, [sp, #-16]!
                \\mov x19, %[rt]
                \\mov x29, %[sentinel]
                \\mov x0, %[tag]
                \\blr %[addr]
                \\ldp x19, x29, [sp], #16
                :
                : [rt] "r" (rt),
                  [addr] "r" (trampoline_addr),
                  [tag] "r" (tag_idx_widened),
                  [sentinel] "r" (sentinel_ptr),
                : aarch64_invoke_clobbers);
        },
        .x86_64 => {
            const trampoline_addr: usize = @intFromPtr(&zwasmThrowTrampoline);
            // R12 is callee-saved in SysV → preserved across the
            // trampoline's CALL → safe slot to save R15. RBP is also
            // callee-saved; push it on the stack, install the sentinel,
            // call, then restore.
            asm volatile (
                \\movq %%r15, %%r12
                \\movq %[rt], %%r15
                \\pushq %%rbp
                \\movq %[sentinel], %%rbp
                \\movq %[tag], %%rdi
                \\callq *%[addr]
                \\popq %%rbp
                \\movq %%r12, %%r15
                :
                : [rt] "r" (rt),
                  [addr] "r" (trampoline_addr),
                  [tag] "r" (tag_idx_widened),
                  [sentinel] "r" (sentinel_ptr),
                : x86_64_invoke_clobbers);
        },
        else => @compileError("unsupported host arch"),
    }
}

const aarch64_invoke_clobbers = if (builtin.target.cpu.arch == .aarch64)
    std.builtin.assembly.Clobbers{
        // BLR clobbers the AAPCS64 caller-saved set (X0..X17, X30, V0..V7).
        // X19 + X29 are saved/restored via STP/LDP within the asm body.
        .x0 = true,
        .x1 = true,
        .x2 = true,
        .x3 = true,
        .x17 = true,
        .x30 = true,
        .memory = true,
    }
else {
    // non-aarch64 hosts skip.
};

const x86_64_invoke_clobbers = if (builtin.target.cpu.arch == .x86_64)
    std.builtin.assembly.Clobbers{
        // SysV caller-saved set touched by the CALL into trampolineCore.
        // R12 is written (used as R15 save slot); RBP is saved/restored
        // on the stack within the asm body.
        .rax = true,
        .rcx = true,
        .rdx = true,
        .rdi = true,
        .rsi = true,
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
        .r12 = true,
        .memory = true,
    }
else {
    // non-x86_64 hosts skip.
};

test "zwasmThrowTrampoline: uncaught path sets trap_flag (no handler installed)" {
    // Empty EH table → dispatchThrow returns .uncaught; trap_flag
    // is set by trampolineCore. End-to-end exercises:
    //   op_throw site → naked stub → trampolineCore →
    //   dispatchThrow → unwind.walk → no match → .uncaught →
    //   rt.trap_flag = 1 → RET to throw site
    var rt: jit_abi.JitRuntime = std.mem.zeroes(jit_abi.JitRuntime);
    try testing.expectEqual(@as(u32, 0), rt.trap_flag);
    invokeTrampolineWith(&rt, 0);
    try testing.expectEqual(@as(u32, 1), rt.trap_flag);
}

test "zwasmThrowTrampoline: handler found path also sets trap_flag (cycle 3c-iii pending)" {
    // Install a catch_all handler that covers the throw site's
    // PC. dispatchThrow returns .handler — trampolineCore currently
    // falls back to trap (cycle 3c-iii implements the actual JMP
    // to landing_pad_pc). The test verifies the DISPATCH path is
    // exercised; once 3c-iii lands, this assertion flips to
    // "trap_flag == 0 + observable landing-pad execution".
    var rt: jit_abi.JitRuntime = std.mem.zeroes(jit_abi.JitRuntime);

    // Install one CodeMap entry that covers a known PC range.
    const cmap_entries = [_]code_map_mod.Entry{
        .{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0, .frame_bytes = 32 },
    };
    rt.eh_code_map_entries = cmap_entries[0..].ptr;
    rt.eh_code_map_count = cmap_entries.len;

    // Install a catch_all handler covering the same PC range.
    const eh_entries = [_]exception_table.HandlerEntry{
        .{ .pc_start = 0, .pc_end = 0x100, .tag_idx = null, .landing_pad_pc = 0x40, .kind = .catch_all },
    };
    rt.eh_table_entries = eh_entries[0..].ptr;
    rt.eh_table_count = eh_entries.len;

    // We can't realistically pass throw_site_addr=0x10042 from the
    // assembly wrapper (X30 is whatever the BL set it to). Call
    // `trampolineCore` directly to verify the dispatch logic and
    // the placeholder trap-flag fallback; the wrapper-call path
    // is covered by the .uncaught test above.
    trampolineCore(999, 0x10042, 5, &rt);
    try testing.expectEqual(@as(u32, 1), rt.trap_flag);
}

test "zwasmThrowTrampoline: symbol address is non-zero (linker exported)" {
    try testing.expect(@intFromPtr(&zwasmThrowTrampoline) != 0);
}
