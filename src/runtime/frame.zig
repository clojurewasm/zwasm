//! WASM Spec §4.2.10 "Frames" + §4.2.11 "Activations" + label
//! stack.
//!
//! Per ADR-0023 §3 P-D: extracted from the previous
//! `runtime/runtime.zig` so each WASM Spec §4.2 concept owns its
//! file. `max_operand_stack` / `max_frame_stack` /
//! `max_label_stack` constants live here because they bound the
//! frame's inline buffers; per ROADMAP §P3 (cold-start: no
//! per-call allocation) the buffers are inline-fixed.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const value = @import("value.zig");
const trap_mod = @import("trap.zig");
const zir = @import("../ir/zir.zig");

const FuncType = zir.FuncType;
const Value = value.Value;
const Trap = trap_mod.Trap;

pub const max_operand_stack: u32 = 4096;
pub const max_frame_stack: u32 = 256;
pub const max_label_stack: u32 = 128;

/// Control-label record. `block` / `if` push a label whose
/// `target_pc` points one past the matching `end`; `loop` pushes a
/// label whose `target_pc` points just after the `loop` opcode (so
/// that `br` to a loop re-enters the body).
///
/// Two arities because `loop` distinguishes them: `arity` is the
/// number of result values the matching `end` transfers (i.e. the
/// blocktype's result count); `branch_arity` is the number a `br`
/// to this label transfers (= results for block/if; = params for
/// loop, which is 0 in Wasm 1.0 — multivalue loop-with-params is
/// a Phase 2 carry-over per ROADMAP §9.2 chunk 3b).
pub const Label = struct {
    height: u32,
    arity: u32,
    branch_arity: u32,
    target_pc: u32,
};

comptime {
    // ADR-0014 §6.K.5 + `.claude/rules/single_slot_dual_meaning.md`:
    // the dual-arity split is load-bearing. `arity` is consumed by
    // `endOp` (= block/loop result count); `branch_arity` is
    // consumed by `brOp` (= block/if results, but loop *params*).
    // Iter 11 of §9.6 / 6.E (commit 7b26760) split a previously
    // single `arity` slot after `tinygo_fib`'s `loop (result i32)`
    // dispatched the wrong pop-count. A future merge that drops
    // either field would silently re-introduce the underflow; this
    // assertion fails compilation if that happens.
    if (!@hasField(Label, "arity") or !@hasField(Label, "branch_arity")) {
        @compileError("Label.arity and Label.branch_arity must remain split per §14 (single_slot_dual_meaning).");
    }
}

/// Per-call activation record. `locals` holds params followed by
/// declared locals (validator's local-index space). `operand_base`
/// is the operand-stack height at frame entry — `end` / `return`
/// pop the stack down to this height before pushing results.
/// `pc` is the instruction index into the corresponding
/// `ZirFunc.instrs` array.
pub const Frame = struct {
    sig: FuncType,
    locals: []Value,
    operand_base: u32,
    pc: u32,
    /// Borrowed pointer to the active `ZirFunc` so control-flow
    /// handlers can resolve `instr.payload` (a block index) into
    /// `BlockInfo` (`start_inst`, `end_inst`, `else_inst`). Set
    /// by `call` / external runner; left null for ad-hoc test
    /// frames that don't exercise control flow.
    func: ?*const zir.ZirFunc = null,
    /// Set by `end` / `return` handlers to signal the dispatch
    /// loop to break out of the body. Distinct from `pc >=
    /// instrs.len` so handlers can stop early without computing
    /// the bound themselves.
    done: bool = false,

    label_buf: [max_label_stack]Label = undefined,
    label_len: u32 = 0,

    pub fn pushLabel(self: *Frame, l: Label) Trap!void {
        if (self.label_len == max_label_stack) return Trap.StackOverflow;
        self.label_buf[self.label_len] = l;
        self.label_len += 1;
    }

    pub fn popLabel(self: *Frame) Label {
        std.debug.assert(self.label_len > 0);
        self.label_len -= 1;
        return self.label_buf[self.label_len];
    }

    /// Index 0 = innermost. Caller must ensure depth < label_len.
    pub fn labelAt(self: *Frame, depth: u32) Label {
        std.debug.assert(depth < self.label_len);
        return self.label_buf[self.label_len - 1 - depth];
    }
};

const testing = std.testing;

test "Label: arity and branch_arity hold distinct values without aliasing (ADR-0014 §6.K.5)" {
    const l: Label = .{
        .height = 0,
        .arity = 1, // matches `loop (result i32)`'s end-arity
        .branch_arity = 0, // matches `br` to a Wasm-1.0 loop (no params)
        .target_pc = 42,
    };
    try testing.expectEqual(@as(u32, 1), l.arity);
    try testing.expectEqual(@as(u32, 0), l.branch_arity);
    try testing.expect(l.arity != l.branch_arity);
}
