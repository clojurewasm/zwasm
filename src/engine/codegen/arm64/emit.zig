//! ZIR → ARM64 emit pass (§9.7 / 7.3 — skeleton).
//!
//! Walks a `ZirFunc.instrs` stream (consumed in def_pc order)
//! and emits a fixed-width AArch64 instruction stream into a
//! caller-supplied byte buffer. Slot ids from the §9.7 / 7.1
//! regalloc map to physical X-registers via §9.7 / 7.2's
//! `abi.slotToReg`.
//!
//! Phase 7.3 skeleton scope (this commit):
//! - Function prologue: save FP/LR, set up frame pointer.
//! - Function epilogue: restore FP/LR, RET.
//! - `i32.const` → `MOVZ Xd, #imm16` (lower 16 bits) +
//!   optional `MOVK` lanes for the upper 16 bits. Emits to a
//!   single result register dictated by the function's return
//!   slot.
//! - `end` of function → epilogue.
//!
//! Other op handlers land in subsequent §9.7 / 7.3 commits
//! per the row's "produce function bodies" exit; the §9.7 / 7.4
//! spec-pass gate is what closes the full op-coverage loop.
//!
//! AAPCS64 prologue / epilogue shape (per Arm IHI 0055 §6.4):
//!
//!   prologue:
//!     STP FP, LR, [SP, #-16]!     // push FP/LR pair
//!     MOV FP, SP                   // set frame pointer
//!     [optional: SUB SP, SP, #N for locals]
//!
//!   epilogue:
//!     [optional: ADD SP, SP, #N]
//!     LDP FP, LR, [SP], #16        // pop FP/LR pair
//!     RET
//!
//! For 7.3 skeleton we omit the optional stack-frame
//! adjustment (no spilled vregs in straight-line MVP code with
//! ≤17 GPRs available; spills are §9.7 / 7.3 follow-up).
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const Xn = inst.Xn;

pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

pub const CallFixup = struct {
    /// Byte offset within the emitted bytes where a `BL`
    /// placeholder lives. The caller (post-emit linker / runtime
    /// harness) computes the target address relative to the
    /// patch site and rewrites the imm26 field.
    byte_offset: u32,
    /// Wasm function index the call targets. The caller resolves
    /// this against its function-body layout to produce the
    /// concrete disp.
    target_func_idx: u32,
};

pub const EmitOutput = struct {
    /// Encoded function body bytes (little-endian u32 stream).
    /// Caller owns; pair with `deinit` to free.
    bytes: []u8,
    /// Distinct GPR slots used (mirrors `Allocation.n_slots`).
    /// The §9.7 / 7.4 gate consults this for stack-frame sizing
    /// when the spill follow-up lands.
    n_slots: u8,
    /// `BL` fixup sites. Each is a placeholder that the caller
    /// patches once function-body addresses are known.
    /// Caller-owned; pair with `deinit` to free.
    call_fixups: []CallFixup,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
}

/// Emit ARM64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here).
///
/// `func_sigs[k]` is the FuncType of function index `k`; consulted
/// by the `call N` handler to pick the result register class
/// (W0/X0/S0/D0). `module_types[t]` is the FuncType for type
/// index `t`; consulted by `call_indirect type_idx`. Both default
/// to empty slices for tests that don't exercise calls — the call
/// handlers fail with `AllocationMissing` if the index is out of
/// range, so callers must size the tables to the called indices.
pub fn compile(
    allocator: Allocator,
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
) Error!EmitOutput {
    if (alloc.slots.len != (func.liveness orelse return Error.AllocationMissing).ranges.len) {
        return Error.AllocationMissing;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // ============================================================
    // Prologue: STP FP, LR, [SP, #-16]! ; MOV FP, SP ; SUB SP, SP, #frame
    //
    // Locals layout (per ZirFunc.locals; params unsupported in this
    // skeleton — see scope note below): each i32 local occupies an
    // 8-byte slot at [SP, #(K*8)] for stable 8-byte alignment +
    // simple imm12 LDR/STR W addressing. Frame size rounds up to
    // 16 bytes per AAPCS64 §6.4 (SP must stay 16-byte aligned).
    // ============================================================
    if (func.sig.params.len > 0) return Error.UnsupportedOp;
    const num_locals: u32 = @intCast(func.locals.len);
    const locals_bytes: u32 = num_locals * 8;
    // ADR-0018: extend frame by spill region. Layout:
    //   [SP + 0 .. locals_bytes-1]                   locals
    //   [SP + locals_bytes .. +spill_bytes-1]        spills
    // `spill_base_off` is the absolute SP-relative offset where
    // spill slot 0 lives; `gprLoadSpilled`/`gprStoreSpilled`
    // consume it via byte_offset = spill_base_off + slot.spill.
    const spill_bytes: u32 = alloc.spillBytes();
    const spill_base_off: u32 = locals_bytes;
    const frame_bytes_unaligned: u32 = locals_bytes + spill_bytes;
    const frame_bytes: u32 = (frame_bytes_unaligned + 15) & ~@as(u32, 15);
    try writeU32(allocator, &buf, encStpFpLrPreIdx());
    try writeU32(allocator, &buf, encMovSpToFp());
    // ADR-0017 prologue: 5 LDRs from X0 = `*const JitRuntime`
    // into the reserved invariant regs. Per ROADMAP §2 P3 (cold-
    // start over peak throughput), 5 cycles uncached overhead is
    // acceptable for Phase 7 baseline; Phase 15 optimisation may
    // elide loads when the function provably doesn't use the
    // corresponding invariant.
    try writeU32(allocator, &buf, inst.encLdrImm(28, 0, jit_abi.vm_base_off));
    try writeU32(allocator, &buf, inst.encLdrImm(27, 0, jit_abi.mem_limit_off));
    try writeU32(allocator, &buf, inst.encLdrImm(26, 0, jit_abi.funcptr_base_off));
    try writeU32(allocator, &buf, inst.encLdrImmW(25, 0, jit_abi.table_size_off));
    try writeU32(allocator, &buf, inst.encLdrImm(24, 0, jit_abi.typeidx_base_off));
    // ADR-0017 sub-2d-ii: save runtime ptr to X19 so multi-call
    // functions can restore X0 before each BL/BLR. X19 is callee-
    // saved per AAPCS64 — preserved across calls without explicit
    // save/restore.
    try writeU32(allocator, &buf, inst.encOrrReg(abi.runtime_ptr_save_gpr, 31, 0));
    if (frame_bytes > 0) {
        if (frame_bytes >= (@as(u32, 1) << 12)) return Error.SlotOverflow;
        try writeU32(allocator, &buf, inst.encSubImm12(31, 31, @intCast(frame_bytes)));
    }

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // For Phase 7.3 skeleton: track a "result vreg" cursor that
    // records which vreg holds the latest pushed value. The
    // function's `end` reads that vreg, ensures it ends up in X0
    // (the AAPCS64 return register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;

    // ============================================================
    // Label stack — supports `block` / `loop` + `br N` / `br_if N`.
    //
    // Each entry tracks:
    //   kind      — .block (forward branches resolve at `end`) or
    //               .loop (backward branches resolve at the loop
    //               entry).
    //   target_byte_offset — for .loop, the byte offset of the
    //               loop entry. For .block, undefined until `end`
    //               lands; pending fixups are patched at that
    //               point.
    //   pending   — fixup records (byte_offset of branch + kind)
    //               needing patch when the label resolves.
    //
    // This lives in emit.zig (not as a separate type) because the
    // patching machinery is tightly coupled to the buf layout.
    // ============================================================
    const LabelKind = enum { block, loop, if_then, else_open };
    const FixupKind = enum { b_uncond, cbnz_w };
    const Fixup = struct { byte_offset: u32, kind: FixupKind };
    const Label = struct {
        kind: LabelKind,
        target_byte_offset: u32,
        pending: std.ArrayList(Fixup),
        /// When `.if_then`, byte offset of the CBZ that skips
        /// the then-body. Patched at `else` (to else-body start)
        /// or at `end` (to end of if). Cleared when transitioning
        /// to `.else_open`.
        if_skip_byte: ?u32 = null,
        /// D-027 fix (sub-7.5c-vi): for `if (result T)` blocks,
        /// the then arm's result vreg is captured at `else`;
        /// the else arm's result is MOVed into this vreg's
        /// register at the if-frame's `end` so both paths
        /// converge on the same physical reg. Null for blocks
        /// without arity OR when no `else` was emitted.
        merge_top_vreg: ?u32 = null,
    };
    var labels: std.ArrayList(Label) = .empty;
    defer {
        for (labels.items) |*l| l.pending.deinit(allocator);
        labels.deinit(allocator);
    }

    // ============================================================
    // Memory-bounds trap fixup list (sub-f1).
    //
    // Caller-supplied invariants for memory ops in this skeleton:
    //   X28 = vm_base    (memory_base pointer)
    //   X27 = mem_limit  (size in bytes)
    // The caller arranges these before invoking the JIT body.
    // Phase-7 follow-up wires Runtime → these regs structurally
    // (D-014 `Runtime.io` injection point dissolves there).
    //
    // Each i32.load / i32.store / etc. emits:
    //   ORR W16, WZR, W_addr   ; zero-extend addr to X16
    //   ADD X16, X16, #imm     ; effective addr
    //   CMP X16, X27           ; bounds
    //   B.HS  trap_stub        ; branch on unsigned >= (placeholder + fixup)
    //   LDR/STR W_dest, [X28, X16]
    //
    // The B.HS fixup byte_offset is appended here. At function-final
    // `end`, after the regular epilogue+RET, a trap stub is emitted
    // and all bounds_fixups are patched to point at it.
    var bounds_fixups: std.ArrayList(u32) = .empty;
    defer bounds_fixups.deinit(allocator);

    // Call fixup list — exposed via EmitOutput for the post-emit
    // linker / runtime to patch with concrete func-body offsets.
    // Sub-g1 skeleton: only `call` is supported; call_indirect
    // lands in sub-g2 with a different mechanism (table lookup +
    // BLR).
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    for (func.instrs.items, 0..) |ins, pc| {
        _ = pc;
        switch (ins.op) {
            .@"i32.const" => {
                // The const's destination vreg is the next-to-be-pushed
                // vreg id. Slot it; if spilled, materialise into a
                // stage reg + STR to the spill frame (sub-1c).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xd = try gprDefSpilled(alloc, vreg, 0);
                try emitConstU32(allocator, &buf, xd, ins.payload);
                try gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.const" => {
                // ZirInstr packs u64 across (payload, extra):
                //   low_32 = payload, high_32 = extra.
                // Emit MOVZ (low 16) + MOVK lanes for any non-zero
                // upper lane. MOVZ zeros, MOVK keeps lower lanes.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xd = try resolveGpr(alloc, vreg);
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                const lane0: u16 = @truncate(value & 0xFFFF);
                const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
                const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
                const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
                try writeU32(allocator, &buf, inst.encMovzImm16(xd, lane0));
                if (lane1 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(xd, lane1, 1));
                if (lane2 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(xd, lane2, 2));
                if (lane3 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(xd, lane3, 3));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.add",
            .@"i64.sub",
            .@"i64.mul",
            .@"i64.and",
            .@"i64.or",
            .@"i64.xor",
            => {
                // Binary i64 ALU: pop rhs, lhs; allocate result;
                // emit X-variant op (64-bit semantics; no
                // zero-extension fixup since i64 is the full
                // register).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const xm = try resolveGpr(alloc, rhs);
                const xd = try resolveGpr(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"i64.add" => inst.encAddReg(xd, xn, xm),
                    .@"i64.sub" => inst.encSubReg(xd, xn, xm),
                    .@"i64.mul" => inst.encMulReg(xd, xn, xm),
                    .@"i64.and" => inst.encAndReg(xd, xn, xm),
                    .@"i64.or"  => inst.encOrrReg(xd, xn, xm),
                    .@"i64.xor" => inst.encEorReg(xd, xn, xm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.eq",
            .@"i64.ne",
            .@"i64.lt_s",
            .@"i64.lt_u",
            .@"i64.gt_s",
            .@"i64.gt_u",
            .@"i64.le_s",
            .@"i64.le_u",
            .@"i64.ge_s",
            .@"i64.ge_u",
            => {
                // 2-instr CMP-X + CSET-W. CMP is X-variant (64-bit
                // compare); CSET writes 0/1 to a W-register (the
                // i32 result type per Wasm spec).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const xm = try resolveGpr(alloc, rhs);
                const wd = try resolveGpr(alloc, result);
                const cond: inst.Cond = switch (ins.op) {
                    .@"i64.eq"   => .eq,
                    .@"i64.ne"   => .ne,
                    .@"i64.lt_s" => .lt,
                    .@"i64.lt_u" => .lo,
                    .@"i64.gt_s" => .gt,
                    .@"i64.gt_u" => .hi,
                    .@"i64.le_s" => .le,
                    .@"i64.le_u" => .ls,
                    .@"i64.ge_s" => .ge,
                    .@"i64.ge_u" => .hs,
                    else => unreachable,
                };
                try writeU32(allocator, &buf, inst.encCmpRegX(xn, xm));
                try writeU32(allocator, &buf, inst.encCsetW(wd, cond));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.eqz" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encCmpImmX(xn, 0));
                try writeU32(allocator, &buf, inst.encCsetW(wd, .eq));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.shl",
            .@"i64.shr_s",
            .@"i64.shr_u",
            .@"i64.rotr",
            => {
                // Direct X-variant shifts.
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const xm = try resolveGpr(alloc, rhs);
                const xd = try resolveGpr(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"i64.shl"   => inst.encLslvRegX(xd, xn, xm),
                    .@"i64.shr_s" => inst.encAsrvRegX(xd, xn, xm),
                    .@"i64.shr_u" => inst.encLsrvRegX(xd, xn, xm),
                    .@"i64.rotr"  => inst.encRorvRegX(xd, xn, xm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.rotl" => {
                // No direct LEFT rotate on ARM. rotl(val, n) =
                // ror(val, 64-n). 3-instr sequence with IP0 (X16)
                // as scratch:
                //   MOVZ X16, #64
                //   SUB  X16, X16, Xcount
                //   ROR  Xd,  Xval, X16
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const xm = try resolveGpr(alloc, rhs);
                const xd = try resolveGpr(alloc, result);
                const ip0: inst.Xn = 16;
                try writeU32(allocator, &buf, inst.encMovzImm16(ip0, 64));
                try writeU32(allocator, &buf, inst.encSubReg(ip0, ip0, xm));
                try writeU32(allocator, &buf, inst.encRorvRegX(xd, xn, ip0));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.clz" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const xd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encClzX(xd, xn));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.ctz" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const xd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encRbitX(xd, xn));
                try writeU32(allocator, &buf, inst.encClzX(xd, xd));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.wrap_i64", .@"i64.extend_i32_u" => {
                // Both lower to MOV Wd, Wn (= ORR Wd, WZR, Wn).
                // i32.wrap_i64: read the source's lower 32 bits.
                // i64.extend_i32_u: zero-extend (W-write implicitly
                // zeros upper 32 bits of the X register).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encOrrRegW(wd, 31, wn));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.extend_i32_s" => {
                // SXTW Xd, Wn — sign-extend 32-bit into 64-bit.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const xd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encSxtw(xd, wn));
                try pushed_vregs.append(allocator, result);
            },
            // sub-h2: int → float convert. Source is GPR slot
            // (i32→W, i64→X), dest is V slot (f32→S, f64→D).
            .@"f32.convert_i32_s",
            .@"f32.convert_i32_u",
            .@"f32.convert_i64_s",
            .@"f32.convert_i64_u",
            .@"f64.convert_i32_s",
            .@"f64.convert_i32_u",
            .@"f64.convert_i64_s",
            .@"f64.convert_i64_u",
            => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const src = try resolveGpr(alloc, lhs);
                const vd = try resolveFp(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"f32.convert_i32_s" => inst.encScvtfSFromW(vd, src),
                    .@"f32.convert_i32_u" => inst.encUcvtfSFromW(vd, src),
                    .@"f32.convert_i64_s" => inst.encScvtfSFromX(vd, src),
                    .@"f32.convert_i64_u" => inst.encUcvtfSFromX(vd, src),
                    .@"f64.convert_i32_s" => inst.encScvtfDFromW(vd, src),
                    .@"f64.convert_i32_u" => inst.encUcvtfDFromW(vd, src),
                    .@"f64.convert_i64_s" => inst.encScvtfDFromX(vd, src),
                    .@"f64.convert_i64_u" => inst.encUcvtfDFromX(vd, src),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            // sub-h3a: Wasm 1.0 trapping trunc, f32 source.
            // NaN + range checks (per `emitTrunc32BoundsCheck`),
            // then FCVTZS/U. Bounds tables encode the per-op
            // boundary (representable f32 hex) and lower-cmp
            // strictness — for u32/u64 destination, lower=-1.0f
            // with .le; for s32, lower is just below INT_MIN with
            // .le; for s64 same shape with the i64 boundary. f64
            // source (sub-h3b) lands next cycle with f64 bounds.
            .@"i32.trunc_f32_s",
            .@"i32.trunc_f32_u",
            .@"i64.trunc_f32_s",
            .@"i64.trunc_f32_u",
            => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const dest = try resolveGpr(alloc, result);

                const Bounds = struct { lo: u32, hi: u32, lo_cmp: inst.Cond };
                const b: Bounds = switch (ins.op) {
                    .@"i32.trunc_f32_s" => .{ .lo = 0xCF000001, .hi = 0x4F000000, .lo_cmp = .le }, // -2147483904f, 2^31
                    .@"i32.trunc_f32_u" => .{ .lo = 0xBF800000, .hi = 0x4F800000, .lo_cmp = .le }, // -1.0f, 2^32
                    .@"i64.trunc_f32_s" => .{ .lo = 0xDF000001, .hi = 0x5F000000, .lo_cmp = .le }, // -9223373136366403584f, 2^63
                    .@"i64.trunc_f32_u" => .{ .lo = 0xBF800000, .hi = 0x5F800000, .lo_cmp = .le }, // -1.0f, 2^64
                    else => unreachable,
                };
                try emitTrunc32BoundsCheck(allocator, &buf, vn, b.lo, b.hi, b.lo_cmp, &bounds_fixups);
                const word: u32 = switch (ins.op) {
                    .@"i32.trunc_f32_s" => inst.encFcvtzsWFromS(dest, vn),
                    .@"i32.trunc_f32_u" => inst.encFcvtzuWFromS(dest, vn),
                    .@"i64.trunc_f32_s" => inst.encFcvtzsXFromS(dest, vn),
                    .@"i64.trunc_f32_u" => inst.encFcvtzuXFromS(dest, vn),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            // sub-h3b: Wasm 1.0 trapping trunc, f64 source.
            // Mirror of h3a but with f64 bounds (8-byte constants
            // staged via emitConstU64 through X16) and FCMP/FCVTZ
            // D-form. The bounds use exact f64 representations
            // (i32 boundary INT_MIN-1 IS representable in f64;
            // i64 boundary -2^63 IS representable so uses .lt
            // strict instead of .le).
            .@"i32.trunc_f64_s",
            .@"i32.trunc_f64_u",
            .@"i64.trunc_f64_s",
            .@"i64.trunc_f64_u",
            => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const dest = try resolveGpr(alloc, result);

                const Bounds = struct { lo: u64, hi: u64, lo_cmp: inst.Cond };
                const b: Bounds = switch (ins.op) {
                    .@"i32.trunc_f64_s" => .{ .lo = 0xC1E0000000200000, .hi = 0x41E0000000000000, .lo_cmp = .le }, // -(2^31+1), 2^31
                    .@"i32.trunc_f64_u" => .{ .lo = 0xBFF0000000000000, .hi = 0x41F0000000000000, .lo_cmp = .le }, // -1.0, 2^32
                    .@"i64.trunc_f64_s" => .{ .lo = 0xC3E0000000000000, .hi = 0x43E0000000000000, .lo_cmp = .lt }, // -2^63 (.lt strict), 2^63
                    .@"i64.trunc_f64_u" => .{ .lo = 0xBFF0000000000000, .hi = 0x43F0000000000000, .lo_cmp = .le }, // -1.0, 2^64
                    else => unreachable,
                };
                try emitTrunc64BoundsCheck(allocator, &buf, vn, b.lo, b.hi, b.lo_cmp, &bounds_fixups);
                const word: u32 = switch (ins.op) {
                    .@"i32.trunc_f64_s" => inst.encFcvtzsWFromD(dest, vn),
                    .@"i32.trunc_f64_u" => inst.encFcvtzuWFromD(dest, vn),
                    .@"i64.trunc_f64_s" => inst.encFcvtzsXFromD(dest, vn),
                    .@"i64.trunc_f64_u" => inst.encFcvtzuXFromD(dest, vn),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            // sub-h5: Wasm 2.0 sat_trunc — float→int with saturation.
            // ARM64 FCVTZS/FCVTZU natively saturate on overflow and
            // produce 0 for NaN, matching Wasm 2.0 spec exactly.
            // Source is V-reg (S/D), dest is GPR (W/X).
            .@"i32.trunc_sat_f32_s",
            .@"i32.trunc_sat_f32_u",
            .@"i32.trunc_sat_f64_s",
            .@"i32.trunc_sat_f64_u",
            .@"i64.trunc_sat_f32_s",
            .@"i64.trunc_sat_f32_u",
            .@"i64.trunc_sat_f64_s",
            .@"i64.trunc_sat_f64_u",
            => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const dest = try resolveGpr(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"i32.trunc_sat_f32_s" => inst.encFcvtzsWFromS(dest, vn),
                    .@"i32.trunc_sat_f32_u" => inst.encFcvtzuWFromS(dest, vn),
                    .@"i32.trunc_sat_f64_s" => inst.encFcvtzsWFromD(dest, vn),
                    .@"i32.trunc_sat_f64_u" => inst.encFcvtzuWFromD(dest, vn),
                    .@"i64.trunc_sat_f32_s" => inst.encFcvtzsXFromS(dest, vn),
                    .@"i64.trunc_sat_f32_u" => inst.encFcvtzuXFromS(dest, vn),
                    .@"i64.trunc_sat_f64_s" => inst.encFcvtzsXFromD(dest, vn),
                    .@"i64.trunc_sat_f64_u" => inst.encFcvtzuXFromD(dest, vn),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            // sub-h4: reinterpret (bit-cast). All 4 ops compile to
            // a single FMOV register-class crossing instruction —
            // the underlying bits don't change, just the type the
            // regalloc pools track.
            .@"i32.reinterpret_f32" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encFmovWFromS(wd, vn));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.reinterpret_f64" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const xd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encFmovXFromD(xd, vn));
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.reinterpret_i32" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const vd = try resolveFp(alloc, result);
                try writeU32(allocator, &buf, inst.encFmovStoFromW(vd, wn));
                try pushed_vregs.append(allocator, result);
            },
            .@"f64.reinterpret_i64" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const vd = try resolveFp(alloc, result);
                try writeU32(allocator, &buf, inst.encFmovDtoFromX(vd, xn));
                try pushed_vregs.append(allocator, result);
            },
            // sub-h2: float demote/promote. Both src and dest are
            // V-register slots (f32 ↔ f64).
            .@"f32.demote_f64", .@"f64.promote_f32" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const vd = try resolveFp(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"f32.demote_f64" => inst.encFcvtSFromD(vd, vn),
                    .@"f64.promote_f32" => inst.encFcvtDFromS(vd, vn),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.const" => {
                // Stage the IEEE-754 bits via a GPR const, then
                // FMOV S, W. The intermediate W-reg is the FP
                // vreg's slot's GPR-pool counterpart (slot K → X9+K
                // for K<7, etc.) reused as scratch for the move.
                // Per the per-class slot mapping note in abi.zig
                // (allocatable_v_regs comment), GPR slot 0 maps to
                // X9 — we use that as the immediate scratch.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const vd = try resolveFp(alloc, vreg);
                const w_scratch = try resolveGpr(alloc, vreg);
                try emitConstU32(allocator, &buf, w_scratch, ins.payload);
                try writeU32(allocator, &buf, inst.encFmovStoFromW(vd, w_scratch));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f64.const" => {
                // Similar to f32.const but for 64-bit (FMOV D, X).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const vd = try resolveFp(alloc, vreg);
                const x_scratch = try resolveGpr(alloc, vreg);
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                const lane0: u16 = @truncate(value & 0xFFFF);
                const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
                const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
                const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
                try writeU32(allocator, &buf, inst.encMovzImm16(x_scratch, lane0));
                if (lane1 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane1, 1));
                if (lane2 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane2, 2));
                if (lane3 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane3, 3));
                try writeU32(allocator, &buf, inst.encFmovDtoFromX(vd, x_scratch));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f32.add",
            .@"f32.sub",
            .@"f32.mul",
            .@"f32.div",
            .@"f64.add",
            .@"f64.sub",
            .@"f64.mul",
            .@"f64.div",
            => {
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const vm = try resolveFp(alloc, rhs);
                const vd = try resolveFp(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"f32.add" => inst.encFAddS(vd, vn, vm),
                    .@"f32.sub" => inst.encFSubS(vd, vn, vm),
                    .@"f32.mul" => inst.encFMulS(vd, vn, vm),
                    .@"f32.div" => inst.encFDivS(vd, vn, vm),
                    .@"f64.add" => inst.encFAddD(vd, vn, vm),
                    .@"f64.sub" => inst.encFSubD(vd, vn, vm),
                    .@"f64.mul" => inst.encFMulD(vd, vn, vm),
                    .@"f64.div" => inst.encFDivD(vd, vn, vm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.abs",
            .@"f32.neg",
            .@"f32.sqrt",
            .@"f32.ceil",
            .@"f32.floor",
            .@"f32.trunc",
            .@"f32.nearest",
            .@"f64.abs",
            .@"f64.neg",
            .@"f64.sqrt",
            .@"f64.ceil",
            .@"f64.floor",
            .@"f64.trunc",
            .@"f64.nearest",
            => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const vd = try resolveFp(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"f32.abs"     => inst.encFAbsS(vd, vn),
                    .@"f32.neg"     => inst.encFNegS(vd, vn),
                    .@"f32.sqrt"    => inst.encFSqrtS(vd, vn),
                    .@"f32.ceil"    => inst.encFRintPS(vd, vn),
                    .@"f32.floor"   => inst.encFRintMS(vd, vn),
                    .@"f32.trunc"   => inst.encFRintZS(vd, vn),
                    .@"f32.nearest" => inst.encFRintNS(vd, vn),
                    .@"f64.abs"     => inst.encFAbsD(vd, vn),
                    .@"f64.neg"     => inst.encFNegD(vd, vn),
                    .@"f64.sqrt"    => inst.encFSqrtD(vd, vn),
                    .@"f64.ceil"    => inst.encFRintPD(vd, vn),
                    .@"f64.floor"   => inst.encFRintMD(vd, vn),
                    .@"f64.trunc"   => inst.encFRintZD(vd, vn),
                    .@"f64.nearest" => inst.encFRintND(vd, vn),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.copysign",
            .@"f64.copysign",
            => {
                // ARM has no single copysign; emit FMOV → bit-mask
                // detour. Wasm: result = (|x|) | sign(y).
                //
                // 8-instr sequence (f32) / 8-instr (f64):
                //   MOVZ X16, #0
                //   MOVK X16, #0x8000, lsl #(16 for f32, 48 for f64)
                //   FMOV W_a, S_x  (or X_a, D_x for f64)
                //   BIC W_a, W_a, W16   ; magnitude of x
                //   FMOV W17, S_y  (or X17, D_y)
                //   AND W17, W17, W16   ; sign of y
                //   ORR W_a, W_a, W17
                //   FMOV S_d, W_a  (or D_d, X_a)
                //
                // W_a = slot[result]'s GPR mapping (same slot id
                // as the V-result, but distinct physical reg).
                // IP0 (X16) = mask scratch; IP1 (X17) = sign scratch.
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs_y = pushed_vregs.pop().?; // sign source
                const lhs_x = pushed_vregs.pop().?; // magnitude source
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn_x = try resolveFp(alloc, lhs_x);
                const vm_y = try resolveFp(alloc, rhs_y);
                const vd = try resolveFp(alloc, result);
                const w_a = try resolveGpr(alloc, result);
                const ip0: inst.Xn = 16;
                const ip1: inst.Xn = 17;
                const is_d = ins.op == .@"f64.copysign";
                // Build sign-bit mask in IP0 (lower 32 for f32 in W,
                // top lane for f64 in X):
                try writeU32(allocator, &buf, inst.encMovzImm16(ip0, 0));
                const mask_lsl_hw: u2 = if (is_d) 3 else 1;
                try writeU32(allocator, &buf, inst.encMovkImm16(ip0, 0x8000, mask_lsl_hw));
                if (is_d) {
                    try writeU32(allocator, &buf, inst.encFmovXFromD(w_a, vn_x));
                    try writeU32(allocator, &buf, inst.encBicRegX(w_a, w_a, ip0));
                    try writeU32(allocator, &buf, inst.encFmovXFromD(ip1, vm_y));
                    try writeU32(allocator, &buf, inst.encAndReg(ip1, ip1, ip0));
                    try writeU32(allocator, &buf, inst.encOrrReg(w_a, w_a, ip1));
                    try writeU32(allocator, &buf, inst.encFmovDtoFromX(vd, w_a));
                } else {
                    try writeU32(allocator, &buf, inst.encFmovWFromS(w_a, vn_x));
                    try writeU32(allocator, &buf, inst.encBicRegW(w_a, w_a, ip0));
                    try writeU32(allocator, &buf, inst.encFmovWFromS(ip1, vm_y));
                    try writeU32(allocator, &buf, inst.encAndRegW(ip1, ip1, ip0));
                    try writeU32(allocator, &buf, inst.encOrrRegW(w_a, w_a, ip1));
                    try writeU32(allocator, &buf, inst.encFmovStoFromW(vd, w_a));
                }
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.min",
            .@"f32.max",
            .@"f64.min",
            .@"f64.max",
            => {
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const vm = try resolveFp(alloc, rhs);
                const vd = try resolveFp(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"f32.min" => inst.encFMinS(vd, vn, vm),
                    .@"f32.max" => inst.encFMaxS(vd, vn, vm),
                    .@"f64.min" => inst.encFMinD(vd, vn, vm),
                    .@"f64.max" => inst.encFMaxD(vd, vn, vm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.eq",
            .@"f32.ne",
            .@"f32.lt",
            .@"f32.gt",
            .@"f32.le",
            .@"f32.ge",
            .@"f64.eq",
            .@"f64.ne",
            .@"f64.lt",
            .@"f64.gt",
            .@"f64.le",
            .@"f64.ge",
            => {
                // FCMP S/D → CSET W. Wasm FP cmps are ordered:
                // NaN inputs always yield false. The ARM Cond
                // codes used here naturally satisfy that:
                // - eq/ne: EQ/NE (Z flag; FCMP unordered → Z=0,V=1).
                // - lt: MI (N=1; FCMP unordered → N=0).
                // - gt: GT (Z=0 ∧ N=V).
                // - le: LS (C=0 ∨ Z=1; FCMP unordered → C=1).
                // - ge: GE (N=V; FCMP unordered → N=0,V=1 → false).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = try resolveFp(alloc, lhs);
                const vm = try resolveFp(alloc, rhs);
                const wd = try resolveGpr(alloc, result);
                const is_d = switch (ins.op) {
                    .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge" => true,
                    else => false,
                };
                const cond: inst.Cond = switch (ins.op) {
                    .@"f32.eq", .@"f64.eq" => .eq,
                    .@"f32.ne", .@"f64.ne" => .ne,
                    .@"f32.lt", .@"f64.lt" => .mi,
                    .@"f32.gt", .@"f64.gt" => .gt,
                    .@"f32.le", .@"f64.le" => .ls,
                    .@"f32.ge", .@"f64.ge" => .ge,
                    else => unreachable,
                };
                try writeU32(allocator, &buf, if (is_d) inst.encFCmpD(vn, vm) else inst.encFCmpS(vn, vm));
                try writeU32(allocator, &buf, inst.encCsetW(wd, cond));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.popcnt" => {
                // 64-bit popcount via SIMD: same shape as i32.popcnt
                // but FMOV D (not S) stages the full 64 bits into
                // V31's lower 64. CNT/ADDV/UMOV are unchanged
                // (operate on lower 8 bytes regardless of whether
                // upper 4 came from FMOV S or full 8 bytes from
                // FMOV D). Result fits in W (max 64 < 256).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                const v_scratch: inst.Vn = 31;
                try writeU32(allocator, &buf, inst.encFmovDtoFromX(v_scratch, xn));
                try writeU32(allocator, &buf, inst.encCntV8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encAddvB8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encUmovWFromVB0(wd, v_scratch));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.add",
            .@"i32.sub",
            .@"i32.mul",
            .@"i32.and",
            .@"i32.or",
            .@"i32.xor",
            .@"i32.shl",
            .@"i32.shr_s",
            .@"i32.shr_u",
            => {
                // Binary i32 ALU: pop rhs, lhs; allocate result;
                // emit a W-variant op so the upper 32 bits stay
                // zero-extended (Wasm i32 wraps mod 2^32).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wm = try resolveGpr(alloc, rhs);
                const wd = try resolveGpr(alloc, result);
                const word: u32 = switch (ins.op) {
                    .@"i32.add"   => inst.encAddRegW(wd, wn, wm),
                    .@"i32.sub"   => inst.encSubRegW(wd, wn, wm),
                    .@"i32.mul"   => inst.encMulRegW(wd, wn, wm),
                    .@"i32.and"   => inst.encAndRegW(wd, wn, wm),
                    .@"i32.or"    => inst.encOrrRegW(wd, wn, wm),
                    .@"i32.xor"   => inst.encEorRegW(wd, wn, wm),
                    .@"i32.shl"   => inst.encLslvRegW(wd, wn, wm),
                    .@"i32.shr_s" => inst.encAsrvRegW(wd, wn, wm),
                    .@"i32.shr_u" => inst.encLsrvRegW(wd, wn, wm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.rotr" => {
                // rotr is direct: `RORV Wd, Wn, Wm`.
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wm = try resolveGpr(alloc, rhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encRorvRegW(wd, wn, wm));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.rotl" => {
                // ARM has only ROR; rotl(val, n) = ror(val, 32-n).
                // 3-instr sequence using IP0 (W16) as scratch (not
                // in the regalloc pool, safe to clobber):
                //   MOVZ W16, #32
                //   SUB  W16, W16, Wcount
                //   ROR  Wd,  Wval, W16
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wm = try resolveGpr(alloc, rhs);
                const wd = try resolveGpr(alloc, result);
                const ip0: Xn = 16;
                try writeU32(allocator, &buf, inst.encMovzImm16(ip0, 32));
                try writeU32(allocator, &buf, inst.encSubRegW(ip0, ip0, wm));
                try writeU32(allocator, &buf, inst.encRorvRegW(wd, wn, ip0));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.eq",
            .@"i32.ne",
            .@"i32.lt_s",
            .@"i32.lt_u",
            .@"i32.gt_s",
            .@"i32.gt_u",
            .@"i32.le_s",
            .@"i32.le_u",
            .@"i32.ge_s",
            .@"i32.ge_u",
            => {
                // 2-instr CMP + CSET pattern. Each Wasm cmp maps
                // to an ARM `Cond` (set-if-true).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wm = try resolveGpr(alloc, rhs);
                const wd = try resolveGpr(alloc, result);
                const cond: inst.Cond = switch (ins.op) {
                    .@"i32.eq"   => .eq,
                    .@"i32.ne"   => .ne,
                    .@"i32.lt_s" => .lt,
                    .@"i32.lt_u" => .lo,
                    .@"i32.gt_s" => .gt,
                    .@"i32.gt_u" => .hi,
                    .@"i32.le_s" => .le,
                    .@"i32.le_u" => .ls,
                    .@"i32.ge_s" => .ge,
                    .@"i32.ge_u" => .hs,
                    else => unreachable,
                };
                try writeU32(allocator, &buf, inst.encCmpRegW(wn, wm));
                try writeU32(allocator, &buf, inst.encCsetW(wd, cond));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.eqz" => {
                // Compare against #0 then CSET EQ.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encCmpImmW(wn, 0));
                try writeU32(allocator, &buf, inst.encCsetW(wd, .eq));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.clz" => {
                // CLZ has a direct ARM op: `CLZ Wd, Wn`.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encClzW(wd, wn));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.ctz" => {
                // No direct CTZ on ARM; emit RBIT + CLZ (canonical
                // 2-instr idiom — RBIT reverses bits, CLZ then
                // counts trailing zeros of the original).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encRbitW(wd, wn));
                try writeU32(allocator, &buf, inst.encClzW(wd, wd));
                try pushed_vregs.append(allocator, result);
            },
            .@"local.get" => {
                // Push a fresh vreg holding the value loaded from
                // [SP, #(local_idx * 8)].
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const wd = try resolveGpr(alloc, vreg);
                try writeU32(allocator, &buf, inst.encLdrImmW(wd, 31, offset));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.set" => {
                // Pop top vreg, write to [SP, #(local_idx * 8)].
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const src = pushed_vregs.pop().?;
                const ws = try resolveGpr(alloc, src);
                try writeU32(allocator, &buf, inst.encStrImmW(ws, 31, offset));
            },
            .@"local.tee" => {
                // Write top vreg to [SP, #(local_idx * 8)] WITHOUT
                // popping — the value remains pushed.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const src = pushed_vregs.items[pushed_vregs.items.len - 1];
                const ws = try resolveGpr(alloc, src);
                try writeU32(allocator, &buf, inst.encStrImmW(ws, 31, offset));
            },
            .@"i32.popcnt" => {
                // ARM has no GPR-side popcount; the canonical idiom
                // moves the value to a V-register, runs SIMD CNT
                // per-byte, sums 8 bytes via ADDV, and extracts the
                // sum back to a GPR. 4-instr sequence using V31 as
                // scratch (caller-saved per AAPCS64; never in the
                // integer regalloc pool).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = try resolveGpr(alloc, lhs);
                const wd = try resolveGpr(alloc, result);
                const v_scratch: inst.Vn = 31;
                try writeU32(allocator, &buf, inst.encFmovStoFromW(v_scratch, wn));
                try writeU32(allocator, &buf, inst.encCntV8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encAddvB8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encUmovWFromVB0(wd, v_scratch));
                try pushed_vregs.append(allocator, result);
            },
            .@"block" => {
                try labels.append(allocator, .{
                    .kind = .block,
                    .target_byte_offset = 0, // unknown until matching `end`
                    .pending = .empty,
                });
            },
            .@"loop" => {
                try labels.append(allocator, .{
                    .kind = .loop,
                    .target_byte_offset = @intCast(buf.items.len),
                    .pending = .empty,
                });
            },
            .@"br" => {
                // Resolve label at depth = ins.payload (0 = innermost).
                if (ins.payload >= labels.items.len) return Error.UnsupportedOp;
                const tgt_idx = labels.items.len - 1 - ins.payload;
                const tgt = &labels.items[tgt_idx];
                const fixup_at: u32 = @intCast(buf.items.len);
                if (tgt.kind == .loop) {
                    // Backward branch — target is known.
                    const disp_words: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
                        @as(i32, @intCast(fixup_at));
                    try writeU32(allocator, &buf, inst.encB(@divExact(disp_words, 4)));
                } else {
                    // Forward branch — record fixup, emit placeholder.
                    try writeU32(allocator, &buf, inst.encB(0));
                    try tgt.pending.append(allocator, .{ .byte_offset = fixup_at, .kind = .b_uncond });
                }
            },
            .@"call_indirect" => {
                // Type-idx → callee FuncType (sub-g3a).
                if (ins.payload >= module_types.len) return Error.AllocationMissing;
                const callee_sig: zir.FuncType = module_types[ins.payload];

                // Stack at entry: [args..., idx]. Pop idx first.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const idx_vreg = pushed_vregs.pop().?;

                try marshalCallArgs(allocator, &buf, callee_sig, alloc, &pushed_vregs);

                // Sub-g3c: bounds + sig check using the trap-stub at
                // function tail (shared with memory bounds — single
                // trap reason today; Diagnostic M3 / D-022 splits
                // them later).
                const w_idx = try resolveGpr(alloc, idx_vreg);
                try writeU32(allocator, &buf, inst.encOrrRegW(17, 31, w_idx));

                // Bounds: CMP W17, W25 ; B.HS trap.
                try writeU32(allocator, &buf, inst.encCmpRegW(17, 25));
                {
                    const fixup_at: u32 = @intCast(buf.items.len);
                    try writeU32(allocator, &buf, inst.encBCond(.hs, 0));
                    try bounds_fixups.append(allocator, fixup_at);
                }

                // Sig: LDR W16, [X24, X17, LSL #2] ; CMP W16, #expected ; B.NE trap.
                // Skeleton restricts expected typeidx to imm12 range
                // (4096 distinct types is well above any realistic
                // module's needs); larger typeidx → UnsupportedOp,
                // which the lowerer / module-level driver may
                // surface as an explicit bound to the user.
                if (ins.payload >= 4096) return Error.UnsupportedOp;
                try writeU32(allocator, &buf, inst.encLdrWRegLsl2(16, 24, 17));
                try writeU32(allocator, &buf, inst.encCmpImmW(16, @intCast(ins.payload)));
                {
                    const fixup_at: u32 = @intCast(buf.items.len);
                    try writeU32(allocator, &buf, inst.encBCond(.ne, 0));
                    try bounds_fixups.append(allocator, fixup_at);
                }

                // Funcptr load + BLR. Restore X0 = runtime_ptr
                // (ADR-0017 sub-2d-ii) before transferring control.
                try writeU32(allocator, &buf, inst.encLdrXRegLsl3(17, 26, 17));
                try writeU32(allocator, &buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
                try writeU32(allocator, &buf, inst.encBLR(17));

                try captureCallResult(allocator, &buf, callee_sig, alloc, &pushed_vregs, &next_vreg);
            },
            .@"call" => {
                if (ins.payload >= func_sigs.len) return Error.AllocationMissing;
                const callee_sig: zir.FuncType = func_sigs[ins.payload];

                try marshalCallArgs(allocator, &buf, callee_sig, alloc, &pushed_vregs);

                // ADR-0017 sub-2d-ii: restore runtime_ptr in X0
                // (X0 is caller-saved per AAPCS64, may have been
                // clobbered by an earlier call in this function).
                try writeU32(allocator, &buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));

                // BL placeholder; the post-emit linker patches via
                // EmitOutput.call_fixups once function-body offsets
                // are known.
                const fixup_at: u32 = @intCast(buf.items.len);
                try writeU32(allocator, &buf, inst.encBL(0));
                try call_fixups.append(allocator, .{
                    .byte_offset = fixup_at,
                    .target_func_idx = ins.payload,
                });

                try captureCallResult(allocator, &buf, callee_sig, alloc, &pushed_vregs, &next_vreg);
            },
            .@"memory.size" => {
                // Wasm memory.size returns current size in 64-KiB pages.
                // X27 carries the byte limit; pages = bytes >> 16.
                // Pop nothing (Wasm signature: () → i32). Push the
                // result vreg.
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encLsrImmW(wd, 27, 16));
                try pushed_vregs.append(allocator, result);
            },
            .@"memory.grow" => {
                // Skeleton: emit `MOVN Wd, #0` = 0xFFFFFFFF = -1
                // (Wasm spec: -1 indicates grow-failed). Real grow
                // requires a Runtime callout that allocates new
                // pages + updates X27 + the underlying memory_base.
                // Phase 7 follow-up: emit BL to a runtime helper
                // pointer; Runtime.io injection (D-014) dissolves
                // alongside this step.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?; // delta arg, unused in skeleton
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wd = try resolveGpr(alloc, result);
                try writeU32(allocator, &buf, inst.encMovnImmW(wd, 0));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
            .@"i32.load16_s", .@"i32.load16_u",
            .@"i64.load", .@"i64.load8_s", .@"i64.load8_u",
            .@"i64.load16_s", .@"i64.load16_u",
            .@"i64.load32_s", .@"i64.load32_u",
            .@"f32.load", .@"f64.load",
            .@"i32.store", .@"i32.store8", .@"i32.store16",
            .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
            .@"f32.store", .@"f64.store",
            => {
                // Effective-address + bounds-check prologue (sub-f1
                // pattern), then per-op LDR/STR. All memory ops
                // share:
                //   ORR W16, WZR, W_addr   ; zero-extend addr
                //   ADD X16, X16, #offset  ; (skip if 0)
                //   CMP X16, X27            ; vs mem_limit
                //   B.HS trap_stub         ; placeholder + fixup
                // The final LDR/STR encoding differs per op.
                const is_store = switch (ins.op) {
                    .@"i32.store", .@"i32.store8", .@"i32.store16",
                    .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
                    .@"f32.store", .@"f64.store",
                    => true,
                    else => false,
                };
                const is_fp_value = switch (ins.op) {
                    .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
                    else => false,
                };
                const ip0: inst.Xn = 16;
                const offset_imm = ins.payload;
                if (offset_imm > 0xFFF) return Error.SlotOverflow;

                // Pop the address + (for stores) value vreg(s).
                var addr_vreg: u32 = 0;
                var val_vreg: u32 = 0;
                if (is_store) {
                    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                    val_vreg = pushed_vregs.pop().?;
                    addr_vreg = pushed_vregs.pop().?;
                } else {
                    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                    addr_vreg = pushed_vregs.pop().?;
                }
                const w_addr = try resolveGpr(alloc, addr_vreg);

                // Effective-address + bounds prologue.
                try writeU32(allocator, &buf, inst.encOrrRegW(ip0, 31, w_addr));
                if (offset_imm != 0) {
                    try writeU32(allocator, &buf, inst.encAddImm12(ip0, ip0, @intCast(offset_imm)));
                }
                try writeU32(allocator, &buf, inst.encCmpRegX(ip0, 27));
                const fixup_at: u32 = @intCast(buf.items.len);
                try writeU32(allocator, &buf, inst.encBCond(.hs, 0));
                try bounds_fixups.append(allocator, fixup_at);

                // Final LDR/STR. Allocate result vreg first for loads.
                if (is_store) {
                    const wv: inst.Xn = if (is_fp_value)
                        try resolveFp(alloc, val_vreg)
                    else
                        try resolveGpr(alloc, val_vreg);
                    const word: u32 = switch (ins.op) {
                        .@"i32.store"   => inst.encStrWReg(wv, 28, ip0),
                        .@"i32.store8"  => inst.encStrbWReg(wv, 28, ip0),
                        .@"i32.store16" => inst.encStrhWReg(wv, 28, ip0),
                        .@"i64.store"   => inst.encStrXReg(wv, 28, ip0),
                        .@"i64.store8"  => inst.encStrbWReg(wv, 28, ip0),
                        .@"i64.store16" => inst.encStrhWReg(wv, 28, ip0),
                        .@"i64.store32" => inst.encStrWReg(wv, 28, ip0),
                        .@"f32.store"   => inst.encStrSReg(wv, 28, ip0),
                        .@"f64.store"   => inst.encStrDReg(wv, 28, ip0),
                        else => unreachable,
                    };
                    try writeU32(allocator, &buf, word);
                } else {
                    const result = next_vreg;
                    next_vreg += 1;
                    if (result >= alloc.slots.len) return Error.SlotOverflow;
                    const wd: inst.Xn = if (is_fp_value)
                        try resolveFp(alloc, result)
                    else
                        try resolveGpr(alloc, result);
                    const word: u32 = switch (ins.op) {
                        .@"i32.load"     => inst.encLdrWReg(wd, 28, ip0),
                        .@"i32.load8_s"  => inst.encLdrsbWReg(wd, 28, ip0),
                        .@"i32.load8_u"  => inst.encLdrbWReg(wd, 28, ip0),
                        .@"i32.load16_s" => inst.encLdrshWReg(wd, 28, ip0),
                        .@"i32.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
                        .@"i64.load"     => inst.encLdrXReg(wd, 28, ip0),
                        .@"i64.load8_s"  => inst.encLdrsbXReg(wd, 28, ip0),
                        .@"i64.load8_u"  => inst.encLdrbWReg(wd, 28, ip0),
                        .@"i64.load16_s" => inst.encLdrshXReg(wd, 28, ip0),
                        .@"i64.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
                        .@"i64.load32_s" => inst.encLdrswXReg(wd, 28, ip0),
                        .@"i64.load32_u" => inst.encLdrWReg(wd, 28, ip0),
                        .@"f32.load"     => inst.encLdrSReg(wd, 28, ip0),
                        .@"f64.load"     => inst.encLdrDReg(wd, 28, ip0),
                        else => unreachable,
                    };
                    try writeU32(allocator, &buf, word);
                    try pushed_vregs.append(allocator, result);
                }
            },
            .@"br_table" => {
                // Pop index. Then linear CMP+B.NE+B chain for
                // each in-range target, plus an unconditional B
                // to the default at the end.
                //
                // Per ZirInstr encoding (mvp.zig:brTableOp):
                //   payload = count  (number of in-range targets)
                //   extra   = start  (offset into branch_targets array)
                // branch_targets[start..start+count] = case depths
                // branch_targets[start+count]        = default depth
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const idx_vreg = pushed_vregs.pop().?;
                const wn = try resolveGpr(alloc, idx_vreg);
                const count = ins.payload;
                const start = ins.extra;
                if (count >= (@as(u32, 1) << 12)) return Error.SlotOverflow;
                const targets = func.branch_targets.items;
                if (start + count >= targets.len) return Error.UnsupportedOp;

                // Helper emits a `B target_for_depth` (direct backward
                // to loop, or forward placeholder + fixup to block-
                // family label).
                const emitBranchToDepth = struct {
                    fn run(
                        a: Allocator,
                        b: *std.ArrayList(u8),
                        labs: []Label,
                        depth: u32,
                    ) !void {
                        if (depth >= labs.len) return Error.UnsupportedOp;
                        const tgt_idx = labs.len - 1 - depth;
                        const tgt = &labs[tgt_idx];
                        const fixup_at: u32 = @intCast(b.items.len);
                        if (tgt.kind == .loop) {
                            const disp_words: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
                                @as(i32, @intCast(fixup_at));
                            const word = inst.encB(@divExact(disp_words, 4));
                            var bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &bytes, word, .little);
                            try b.appendSlice(a, &bytes);
                        } else {
                            var bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &bytes, inst.encB(0), .little);
                            try b.appendSlice(a, &bytes);
                            try tgt.pending.append(a, .{ .byte_offset = fixup_at, .kind = .b_uncond });
                        }
                    }
                }.run;

                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try writeU32(allocator, &buf, inst.encCmpImmW(wn, @intCast(i)));
                    try writeU32(allocator, &buf, inst.encBCond(.ne, 2));
                    try emitBranchToDepth(allocator, &buf, labels.items, targets[start + i]);
                }
                try emitBranchToDepth(allocator, &buf, labels.items, targets[start + count]);
            },
            .@"if" => {
                // Pop cond vreg. Emit `CBZ Wn, 0` placeholder
                // that skips the then-body when cond=0. The skip
                // target is patched at the matching `else` (to
                // the else-body start) or at `end` (to end-of-if).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const cond = pushed_vregs.pop().?;
                const wn = try resolveGpr(alloc, cond);
                const skip_byte: u32 = @intCast(buf.items.len);
                try writeU32(allocator, &buf, inst.encCbzW(wn, 0));
                try labels.append(allocator, .{
                    .kind = .if_then,
                    .target_byte_offset = 0,
                    .pending = .empty,
                    .if_skip_byte = skip_byte,
                });
            },
            .@"else" => {
                // Emit `B 0` placeholder that jumps from the end
                // of the then-body to the end of the if/else
                // (patched at matching `end`). Then patch the
                // if's CBZ to point to current byte (= start of
                // else-body, right after this B). Transition the
                // label to .else_open.
                //
                // D-027 fix (sub-7.5c-vi): if the then arm pushed
                // a result vreg, capture it as the merge target.
                // The MOV that copies the else arm's result into
                // this vreg's register lands at `end` of the
                // if-frame.
                if (labels.items.len == 0 or
                    labels.items[labels.items.len - 1].kind != .if_then)
                {
                    return Error.UnsupportedOp;
                }
                const lbl_idx = labels.items.len - 1;
                if (pushed_vregs.items.len > 0) {
                    labels.items[lbl_idx].merge_top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                }
                const b_byte: u32 = @intCast(buf.items.len);
                try writeU32(allocator, &buf, inst.encB(0));
                const else_start: u32 = @intCast(buf.items.len);
                const lbl = &labels.items[lbl_idx];
                const skip_byte = lbl.if_skip_byte.?;
                const skip_disp: i32 = @as(i32, @intCast(else_start)) -
                    @as(i32, @intCast(skip_byte));
                const orig_cbz = std.mem.readInt(u32, buf.items[skip_byte..][0..4], .little);
                const cbz_rt: inst.Xn = @intCast(orig_cbz & 0x1F);
                const new_cbz = inst.encCbzW(cbz_rt, @divExact(skip_disp, 4));
                std.mem.writeInt(u32, buf.items[skip_byte..][0..4], new_cbz, .little);
                lbl.if_skip_byte = null;
                lbl.kind = .else_open;
                try lbl.pending.append(allocator, .{ .byte_offset = b_byte, .kind = .b_uncond });
            },
            .@"br_if" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const cond = pushed_vregs.pop().?;
                const wn = try resolveGpr(alloc, cond);
                if (ins.payload >= labels.items.len) return Error.UnsupportedOp;
                const tgt_idx = labels.items.len - 1 - ins.payload;
                const tgt = &labels.items[tgt_idx];
                const fixup_at: u32 = @intCast(buf.items.len);
                if (tgt.kind == .loop) {
                    // Backward conditional branch.
                    const disp_words: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
                        @as(i32, @intCast(fixup_at));
                    try writeU32(allocator, &buf, inst.encCbnzW(wn, @divExact(disp_words, 4)));
                } else {
                    try writeU32(allocator, &buf, inst.encCbnzW(wn, 0));
                    try tgt.pending.append(allocator, .{ .byte_offset = fixup_at, .kind = .cbnz_w });
                }
            },
            .@"end" => {
                // Two distinct forms:
                // (A) Intra-function `end`: pops a label off the stack
                //     and patches forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns.
                //
                // Disambiguation: if `labels` is non-empty, we're in
                // form (A). Otherwise form (B).
                if (labels.items.len > 0) {
                    var lbl = labels.pop().?;
                    defer lbl.pending.deinit(allocator);

                    // D-027 fix (sub-7.5c-vi): if this is an
                    // `else_open` label with a captured merge
                    // target, the else arm's result is on top
                    // of pushed_vregs; emit MOV merge_reg ←
                    // else_result_reg BEFORE the join label so
                    // both arms converge. Then drop the else
                    // arm's result vreg (its value now lives in
                    // the merge target's reg).
                    if (lbl.kind == .else_open and lbl.merge_top_vreg != null) {
                        if (pushed_vregs.items.len < 2) return Error.UnsupportedOp;
                        const else_result = pushed_vregs.pop().?;
                        const merge_vreg = lbl.merge_top_vreg.?;
                        // Sanity: top-of-stack-after-pop should
                        // be the captured merge target.
                        if (pushed_vregs.items[pushed_vregs.items.len - 1] != merge_vreg) {
                            return Error.UnsupportedOp;
                        }
                        const merge_reg = try resolveGpr(alloc, merge_vreg);
                        const else_reg = try resolveGpr(alloc, else_result);
                        if (merge_reg != else_reg) {
                            try writeU32(allocator, &buf, inst.encOrrRegW(merge_reg, 31, else_reg));
                        }
                    }

                    const target_byte: u32 = @intCast(buf.items.len);
                    // Patch the if-then's skip-CBZ if it's still
                    // pending (no `else` was encountered).
                    if (lbl.if_skip_byte) |skip_byte| {
                        const disp: i32 = @as(i32, @intCast(target_byte)) -
                            @as(i32, @intCast(skip_byte));
                        const orig = std.mem.readInt(u32, buf.items[skip_byte..][0..4], .little);
                        const rt: inst.Xn = @intCast(orig & 0x1F);
                        const new_cbz = inst.encCbzW(rt, @divExact(disp, 4));
                        std.mem.writeInt(u32, buf.items[skip_byte..][0..4], new_cbz, .little);
                    }
                    // Patch all forward br fixups that targeted
                    // this label (block, if_then with br inside,
                    // else_open including the else-end B).
                    if (lbl.kind == .block or lbl.kind == .if_then or lbl.kind == .else_open) {
                        for (lbl.pending.items) |fx| {
                            const disp_words: i32 = @as(i32, @intCast(target_byte)) -
                                @as(i32, @intCast(fx.byte_offset));
                            const new_word: u32 = switch (fx.kind) {
                                .b_uncond => inst.encB(@divExact(disp_words, 4)),
                                .cbnz_w => blk: {
                                    const orig = std.mem.readInt(u32, buf.items[fx.byte_offset..][0..4], .little);
                                    const rt: inst.Xn = @intCast(orig & 0x1F);
                                    break :blk inst.encCbnzW(rt, @divExact(disp_words, 4));
                                },
                            };
                            std.mem.writeInt(u32, buf.items[fx.byte_offset..][0..4], new_word, .little);
                        }
                    }
                    // Loop: nothing to patch (backward branches already
                    // had concrete offsets). Both block/loop ends are
                    // still followed by the next instruction.
                    continue;
                }
                // Function-level end (labels stack is empty).
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                    const result_kind = func.sig.results[0];
                    const is_fp = switch (result_kind) {
                        .f32, .f64 => true,
                        .i32, .i64, .v128, .funcref, .externref => false,
                    };
                    if (is_fp) {
                        const src_vn = try resolveFp(alloc, top_vreg);
                        if (src_vn != 0) {
                            // FMOV S0, Sn or FMOV D0, Dn — encoded
                            // via the FP-FP move (FMOV reg-reg).
                            // Encoding: `0 0 0 11110 type 1 0000 0 10 0000 [Rn:5] [Rd:5]`
                            // type = 00 single → 0x1E204000
                            // type = 01 double → 0x1E604000
                            const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                            try writeU32(allocator, &buf, base | (@as(u32, src_vn) << 5));
                        }
                    } else {
                        // GPR result: spill-aware load (sub-1c). For
                        // an in-reg vreg, returns the home reg; for
                        // a spilled vreg, emits LDR X14, [SP, #off]
                        // and returns X14. Then MOV X0, Xsrc.
                        const src_xn = try gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top_vreg, 0);
                        if (src_xn != 0) {
                            try writeU32(allocator, &buf, encOrrZrIntoX0(src_xn));
                        }
                    }
                }
                if (frame_bytes > 0) {
                    try writeU32(allocator, &buf, inst.encAddImm12(31, 31, @intCast(frame_bytes)));
                }
                try writeU32(allocator, &buf, encLdpFpLrPostIdx());
                try writeU32(allocator, &buf, inst.encRet(abi.link_register));

                // Trap stub: emitted after the regular RET when the
                // function had any bounds-check / sig-mismatch /
                // NaN-trap / range-trap fixups. Each fixup's B.cond
                // is patched to land here.
                //
                // Per sub-7.5b-ii (ADR-0017 trap_flag amendment):
                // STR W17, [X19, #trap_flag_off] sets the runtime's
                // trap_flag = 1 (W17 holds the trap indicator).
                // Then a clean MOV X0, #0 + epilogue + RET unwinds
                // — the entry shim distinguishes trap-vs-return by
                // reading runtime.trap_flag, NOT by inspecting the
                // returned value (so a trap doesn't confuse with
                // "returned 0").
                if (bounds_fixups.items.len > 0) {
                    const trap_byte: u32 = @intCast(buf.items.len);
                    try writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
                    try writeU32(allocator, &buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off));
                    try writeU32(allocator, &buf, inst.encMovzImm16(0, 0));
                    if (frame_bytes > 0) {
                        try writeU32(allocator, &buf, inst.encAddImm12(31, 31, @intCast(frame_bytes)));
                    }
                    try writeU32(allocator, &buf, encLdpFpLrPostIdx());
                    try writeU32(allocator, &buf, inst.encRet(abi.link_register));
                    for (bounds_fixups.items) |fx_byte| {
                        const disp_words: i32 = @as(i32, @intCast(trap_byte)) -
                            @as(i32, @intCast(fx_byte));
                        const orig = std.mem.readInt(u32, buf.items[fx_byte..][0..4], .little);
                        // Recover cond from lower 4 bits of B.cond placeholder.
                        const cond: inst.Cond = @enumFromInt(@as(u4, @intCast(orig & 0xF)));
                        const new_word = inst.encBCond(cond, @divExact(disp_words, 4));
                        std.mem.writeInt(u32, buf.items[fx_byte..][0..4], new_word, .little);
                    }
                }
                break;
            },
            else => return Error.UnsupportedOp,
        }
    }

    return .{
        .bytes = try buf.toOwnedSlice(allocator),
        .n_slots = alloc.n_slots,
        .call_fixups = try call_fixups.toOwnedSlice(allocator),
    };
}

fn writeU32(allocator: Allocator, buf: *std.ArrayList(u8), word: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Resolve a vreg's home register (GPR class). Returns the
/// allocated reg or `Error.UnsupportedOp` for spilled vregs.
///
/// **Sub-1b shape** (today): handlers that haven't been migrated
/// to spill-aware emission still use `resolveGpr` and decline
/// (UnsupportedOp) when a spill is needed. **Sub-1c migration**
/// (this cycle, in-progress): per-handler conversion to use
/// `gprLoadSpilled` / `gprStoreSpilled` for actual STR/LDR
/// staging. The `i32.const` handler is the first migrated
/// example; further migrations land per follow-up cycles as
/// realworld fixtures surface needs.
fn resolveGpr(alloc: regalloc.Allocation, vreg: usize) Error!inst.Xn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => Error.UnsupportedOp,
    };
}

/// Resolve a vreg's home for **op operand load**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// emits `LDR X_stage, [SP, #(spill_base_off + spill_off)]`
/// staging through `abi.spill_stage_gprs[stage_idx]` and
/// returns the stage reg.
///
/// `stage_idx` selects which stage reg (0=X14, 1=X15). Use 0
/// for the first/only operand, 1 for the second operand of a
/// binary op (so two spilled operands don't collide).
fn gprLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Xn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => |off| blk: {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            // X-form imm12 scales by 8; max byte offset is 8*4095 = 32760.
            if (abs_off > 32760 or (abs_off & 7) != 0) return Error.SlotOverflow;
            try writeU32(allocator, buf, inst.encLdrImm(stage, 31, @intCast(abs_off)));
            break :blk stage;
        },
    };
}

/// Resolve a vreg's home for **op result def**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// returns the stage reg (caller encodes the op writing into
/// it; then calls `gprStoreSpilled` to flush to the spill
/// slot).
fn gprDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Xn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => abi.spill_stage_gprs[stage_idx],
    };
}

/// Pair of `gprDefSpilled`. After encoding the op (which wrote
/// the result into the stage reg), emits `STR X_stage, [SP,
/// #(spill_base_off + spill_off)]`. No-op for vregs in
/// registers (the result is already in its home).
fn gprStoreSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 32760 or (abs_off & 7) != 0) return Error.SlotOverflow;
            try writeU32(allocator, buf, inst.encStrImm(stage, 31, @intCast(abs_off)));
        },
    }
}

/// FP-class counterpart of `resolveGpr`. Same Step-1c follow-up
/// applies for spill staging through V-class scratch.
fn resolveFp(alloc: regalloc.Allocation, vreg: usize) Error!inst.Vn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => Error.UnsupportedOp,
    };
}

/// Emit the NaN + lower-bound + upper-bound trap sequence for
/// a Wasm 1.0 trapping float→int conversion (sub-h3a, f32 src).
///
/// Sequence (per op): 9 instrs + 3 trap branches.
///   FCMP src, src              ; NaN sets V flag
///   B.VS trap_stub             ; trap on NaN
///   MOVZ W16 + MOVK W16        ; materialize lower-bound bits
///   FMOV S31, W16              ; into V31 (popcnt scratch — not
///                                live across this conversion)
///   FCMP src, S31              ; src vs lower
///   B.<lower_cmp> trap_stub    ; trap below lower
///   MOVZ W16 + MOVK W16        ; materialize upper-bound bits
///   FMOV S31, W16
///   FCMP src, S31              ; src vs upper
///   B.GE trap_stub             ; trap at-or-above upper
///
/// All three trap branches append to `bounds_fixups`, which is
/// patched at the function-tail trap stub (shared with memory
/// bounds + call_indirect; single trap reason today).
fn emitTrunc32BoundsCheck(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    src_v: inst.Vn,
    lower_bits: u32,
    upper_bits: u32,
    lower_cmp: inst.Cond,
    bounds_fixups: *std.ArrayList(u32),
) !void {
    // NaN check: FCMP src, src ; B.VS trap.
    try writeU32(allocator, buf, inst.encFCmpS(src_v, src_v));
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try writeU32(allocator, buf, inst.encBCond(.vs, 0));
        try bounds_fixups.append(allocator, fixup_at);
    }
    // Lower bound: materialise into S31 via W16, then FCMP + trap.
    try emitConstU32(allocator, buf, 16, lower_bits);
    try writeU32(allocator, buf, inst.encFmovStoFromW(31, 16));
    try writeU32(allocator, buf, inst.encFCmpS(src_v, 31));
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try writeU32(allocator, buf, inst.encBCond(lower_cmp, 0));
        try bounds_fixups.append(allocator, fixup_at);
    }
    // Upper bound: materialise + FCMP + B.GE trap.
    try emitConstU32(allocator, buf, 16, upper_bits);
    try writeU32(allocator, buf, inst.encFmovStoFromW(31, 16));
    try writeU32(allocator, buf, inst.encFCmpS(src_v, 31));
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try writeU32(allocator, buf, inst.encBCond(.ge, 0));
        try bounds_fixups.append(allocator, fixup_at);
    }
}

/// f64 counterpart of `emitTrunc32BoundsCheck` — same shape but
/// uses `emitConstU64` (MOVZ + up to 3 MOVKs) staged through X16
/// then FMOV D31, X16 + FCMP D-form. Used by sub-h3b's f64-source
/// trapping trunc.
fn emitTrunc64BoundsCheck(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    src_v: inst.Vn,
    lower_bits: u64,
    upper_bits: u64,
    lower_cmp: inst.Cond,
    bounds_fixups: *std.ArrayList(u32),
) !void {
    try writeU32(allocator, buf, inst.encFCmpD(src_v, src_v));
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try writeU32(allocator, buf, inst.encBCond(.vs, 0));
        try bounds_fixups.append(allocator, fixup_at);
    }
    try emitConstU64(allocator, buf, 16, lower_bits);
    try writeU32(allocator, buf, inst.encFmovDtoFromX(31, 16));
    try writeU32(allocator, buf, inst.encFCmpD(src_v, 31));
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try writeU32(allocator, buf, inst.encBCond(lower_cmp, 0));
        try bounds_fixups.append(allocator, fixup_at);
    }
    try emitConstU64(allocator, buf, 16, upper_bits);
    try writeU32(allocator, buf, inst.encFmovDtoFromX(31, 16));
    try writeU32(allocator, buf, inst.encFCmpD(src_v, 31));
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try writeU32(allocator, buf, inst.encBCond(.ge, 0));
        try bounds_fixups.append(allocator, fixup_at);
    }
}

/// Marshal call arguments per AAPCS64: pop N arg vregs from
/// `pushed_vregs` (in REVERSE — top of stack is the rightmost arg),
/// then emit MOV/FMOV from each arg's home register into W0..W7
/// (i32/i64) or S0..S7 / D0..D7 (f32/f64).
///
/// **No source-clobber risk by construction**: vregs are allocated
/// out of `[X9..X15, X19..X28]` (GPR pool) and `[V16..V30]` (FP
/// pool), neither of which overlaps with the AAPCS64 arg-passing
/// registers `[X0..X7]` / `[V0..V7]`. So a naive sequential MOV
/// per arg is correct without parallel-move analysis.
///
/// **Sub-g3b scope**: ≤ 8 GPR + ≤ 8 FP args. Stack-arg lowering
/// (more than 8 args of a class) is post-MVP — surfaces as
/// `UnsupportedOp`.
fn marshalCallArgs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    callee_sig: zir.FuncType,
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
) !void {
    const n_args: u32 = @intCast(callee_sig.params.len);
    if (n_args == 0) return;
    if (pushed_vregs.items.len < n_args) return Error.AllocationMissing;

    // Pop in reverse stack order: top of stack is arg N-1, deepest
    // is arg 0. Stash them so we can iterate forward (arg 0 first).
    var arg_vregs: [8]u32 = undefined; // limit to 8 args per class; UnsupportedOp below if exceeded
    if (n_args > arg_vregs.len) return Error.UnsupportedOp;
    var i: u32 = n_args;
    while (i > 0) {
        i -= 1;
        arg_vregs[i] = pushed_vregs.pop().?;
    }

    // Per ADR-0017: X0 carries `*const JitRuntime`; Wasm GPR
    // args occupy X1..X7 (one fewer than vanilla AAPCS64).
    // FP args still occupy V0..V7 — V regs are unaffected by
    // the X0 reservation.
    //
    // **sub-2d-i scope**: arg-shift only. The body's prologue
    // sets X0 = runtime_ptr at function entry; body code never
    // writes X0..X7; marshalling targets X1..X7. So at the BL,
    // X0 inherits from the function entry (= runtime_ptr) for
    // a LEAF call. Multi-call functions need X0 save/restore
    // around calls (sub-2d-ii) — until that lands, multi-call
    // bodies will pass junk to the second+ callee.
    var gpr_arg_slot: inst.Xn = 1;
    var fp_arg_slot: inst.Vn = 0;
    var k: u32 = 0;
    while (k < n_args) : (k += 1) {
        const src_vreg = arg_vregs[k];
        switch (callee_sig.params[k]) {
            .i32 => {
                if (gpr_arg_slot >= 8) return Error.UnsupportedOp;
                const ws = try resolveGpr(alloc, src_vreg);
                if (ws != gpr_arg_slot) {
                    try writeU32(allocator, buf, inst.encOrrRegW(gpr_arg_slot, 31, ws));
                }
                gpr_arg_slot += 1;
            },
            .i64 => {
                if (gpr_arg_slot >= 8) return Error.UnsupportedOp;
                const xs = try resolveGpr(alloc, src_vreg);
                if (xs != gpr_arg_slot) {
                    try writeU32(allocator, buf, inst.encOrrReg(gpr_arg_slot, 31, xs));
                }
                gpr_arg_slot += 1;
            },
            .f32 => {
                if (fp_arg_slot >= 8) return Error.UnsupportedOp;
                const vs = try resolveFp(alloc, src_vreg);
                if (vs != fp_arg_slot) {
                    try writeU32(allocator, buf, inst.encFmovSReg(fp_arg_slot, vs));
                }
                fp_arg_slot += 1;
            },
            .f64 => {
                if (fp_arg_slot >= 8) return Error.UnsupportedOp;
                const vs = try resolveFp(alloc, src_vreg);
                if (vs != fp_arg_slot) {
                    try writeU32(allocator, buf, inst.encFmovDReg(fp_arg_slot, vs));
                }
                fp_arg_slot += 1;
            },
            .v128, .funcref, .externref => return Error.UnsupportedOp,
        }
    }
}

/// Capture a call's return value into the next vreg, dispatching
/// on the callee's result type. Per AAPCS64: i32→W0, i64→X0,
/// f32→S0, f64→D0. Single-result MVP only — multi-value returns
/// (Wasm 2.0) land at sub-g3 follow-up. Void callees push nothing.
///
/// Used by both `call` and `call_indirect` once their respective
/// signature lookups (sub-g3a) name the callee's FuncType.
fn captureCallResult(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    callee_sig: zir.FuncType,
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) !void {
    if (callee_sig.results.len == 0) return;
    if (callee_sig.results.len > 1) return Error.UnsupportedOp;

    const result = next_vreg.*;
    next_vreg.* += 1;
    if (result >= alloc.slots.len) return Error.AllocationMissing;
    const slot_id = alloc.slots[result];

    switch (callee_sig.results[0]) {
        .i32 => {
            const wd = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
            if (wd != 0) try writeU32(allocator, buf, inst.encOrrRegW(wd, 31, 0));
        },
        .i64 => {
            const xd = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
            if (xd != 0) try writeU32(allocator, buf, inst.encOrrReg(xd, 31, 0));
        },
        .f32 => {
            const vd = abi.fpSlotToReg(slot_id) orelse return Error.SlotOverflow;
            if (vd != 0) try writeU32(allocator, buf, inst.encFmovSReg(vd, 0));
        },
        .f64 => {
            const vd = abi.fpSlotToReg(slot_id) orelse return Error.SlotOverflow;
            if (vd != 0) try writeU32(allocator, buf, inst.encFmovDReg(vd, 0));
        },
        .v128, .funcref, .externref => return Error.UnsupportedOp,
    }
    try pushed_vregs.append(allocator, result);
}

/// Emit a 32-bit constant into Xd via MOVZ + MOVK pairs.
/// Strategy: MOVZ Xd, #(lo16); if hi16 != 0, MOVK Xd, #hi16, lsl #16.
/// (For a full 64-bit constant — Phase 9+ — extend to 4 lanes.)
fn emitConstU32(allocator: Allocator, buf: *std.ArrayList(u8), xd: Xn, value: u32) !void {
    const lo16: u16 = @truncate(value & 0xFFFF);
    const hi16: u16 = @truncate(value >> 16);
    try writeU32(allocator, buf, inst.encMovzImm16(xd, lo16));
    if (hi16 != 0) {
        try writeU32(allocator, buf, inst.encMovkImm16(xd, hi16, 1));
    }
}

/// Emit a 64-bit constant into Xd via MOVZ (hw=0) + up to 3
/// MOVKs at hw=1,2,3. Halfwords that are zero are skipped after
/// the initial MOVZ. Used by sub-h3b's f64 trapping-trunc
/// bounds (8-byte hex constants like 0xC3E0000000000000 for
/// -2^63), staged through X16 then FMOV D31, X16.
fn emitConstU64(allocator: Allocator, buf: *std.ArrayList(u8), xd: Xn, value: u64) !void {
    const hw0: u16 = @truncate(value & 0xFFFF);
    const hw1: u16 = @truncate((value >> 16) & 0xFFFF);
    const hw2: u16 = @truncate((value >> 32) & 0xFFFF);
    const hw3: u16 = @truncate((value >> 48) & 0xFFFF);
    try writeU32(allocator, buf, inst.encMovzImm16(xd, hw0));
    if (hw1 != 0) try writeU32(allocator, buf, inst.encMovkImm16(xd, hw1, 1));
    if (hw2 != 0) try writeU32(allocator, buf, inst.encMovkImm16(xd, hw2, 2));
    if (hw3 != 0) try writeU32(allocator, buf, inst.encMovkImm16(xd, hw3, 3));
}

// ============================================================
// AAPCS64 prologue / epilogue micro-encodings
//
// These are the four fixed encodings every leaf function body
// uses. Inlined here rather than added to inst.zig because
// they're convention-shaped (always the same operands) — adding
// a dedicated enc* in inst.zig would invite false flexibility.
// ============================================================

/// `STP X29, X30, [SP, #-16]!` — pre-index push of FP/LR pair.
/// Encoding (STP 64-bit pre-indexed):
///   `1010 1001 10 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = -16/8 = -2 (signed) = 7'b1111110 = 0x7E.
/// Rn = 31 (SP), Rt = 29 (FP), Rt2 = 30 (LR).
fn encStpFpLrPreIdx() u32 {
    // 0xA9BF7BFD = STP X29, X30, [SP, #-16]!
    return 0xA9BF7BFD;
}

/// `LDP X29, X30, [SP], #16` — post-index pop of FP/LR pair.
/// Encoding (LDP 64-bit post-indexed):
///   `1010 1000 11 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = +16/8 = 2.
fn encLdpFpLrPostIdx() u32 {
    // 0xA8C17BFD = LDP X29, X30, [SP], #16
    return 0xA8C17BFD;
}

/// `MOV X29, SP` — encoded as `ADD X29, SP, #0` (the canonical
/// MOV between SP-form and a register).
/// Encoding (ADD 64-bit imm, sh=0): `1 00 10001 00 0 0000 0000 0000 [Rn:5] [Rd:5]`
/// Rn = 31 (SP), Rd = 29 (FP).
fn encMovSpToFp() u32 {
    // 0x910003FD = mov x29, sp
    return 0x910003FD;
}

/// `MOV X0, Xsrc` — encoded as `ORR X0, XZR, Xsrc` (the
/// canonical 64-bit register-to-register MOV).
/// Encoding: `1 01 01010 00 0 [Rm:5] 000000 11111 [Rd:5]`
/// = 0xAA0003E0 | (Rm << 16).
fn encOrrZrIntoX0(rm: Xn) u32 {
    return 0xAA0003E0 | (@as(u32, rm) << 16);
}

// ============================================================
// Tests
//
// Byte-offset abstraction (regret #6 / ADR-0021 sub-deliverable a):
// new test sites MUST use `prologue.body_start_offset(has_frame)`
// + relative deltas instead of literal `out.bytes[N..M]`. The
// pattern is demonstrated at 4 representative sites below
// (`empty function`, `(i32.const 42)`, `i32.const 0x12345678`,
// `i32.add`). Bulk migration of the remaining ~128 sites is
// sequenced under §9.7 / 7.5d sub-deliverable b (emit.zig split)
// so the relativisation runs in a single review-friendly cycle
// rather than colliding with this session's design + scaffolding
// commits. The rule in `.claude/rules/edge_case_testing.md`
// (§"Test-side byte offsets must be relative") forbids new
// hardcoded literals from this commit forward.
// ============================================================

const testing = std.testing;
const liveness_mod = @import("../../../ir/analysis/liveness.zig");

test "compile: empty body without liveness errors" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: empty function (no instrs, empty liveness) emits prologue+epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    // No `end` op in the stream → emit walks zero instrs and
    // returns just the prologue (no epilogue). That's the expected
    // shape for a malformed body; the §9.7 / 7.4 gate filters such
    // funcs at validate-time, so emit doesn't enforce well-formedness.
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // 2 prologue u32s = 8 bytes.
    try testing.expectEqual(@as(usize, 32), out.bytes.len);
    // Use the centralised opcode constants; ABI-pinned offsets [0..4] / [4..8].
    try prologue.assertPrologueOpcodes(out.bytes);
}

test "compile: (i32.const 42) end yields 5-instr body returning 42 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream: STP / MOV-FP-SP / MOVZ-X9-#42 / MOV-X0-X9 / LDP / RET
    // = 6 u32 words = 24 bytes.
    try testing.expectEqual(@as(usize, 48), out.bytes.len);

    // Word 0: STP prologue (ABI-pinned per AAPCS64; offset fixed).
    try testing.expectEqual(prologue.FpLrSave.stp_word, std.mem.readInt(u32, out.bytes[0..4], .little));
    // Word 1: MOV X29, SP (ABI-pinned).
    try testing.expectEqual(prologue.FpLrSave.mov_fp_word, std.mem.readInt(u32, out.bytes[4..8], .little));
    // Body words use `prologue.body_start_offset(has_frame)` so a
    // future prologue-shape change updates one helper, not 142 sites.
    const body0 = prologue.body_start_offset(false);
    // Word 2: MOVZ X9, #42 — slot 0 → X9 per abi.slotToReg.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    // Word 3: MOV X0, X9 (ORR X0, XZR, X9).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // Word 4: LDP epilogue.
    try testing.expectEqual(@as(u32, 0xA8C17BFD), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // Word 5: RET.
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
}

test "compile: i32.const 0x12345678 emits MOVZ + MOVK (full 32-bit)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // 7 u32s now: STP / MOV-FP-SP / MOVZ / MOVK / MOV-X0 / LDP / RET.
    try testing.expectEqual(@as(usize, 52), out.bytes.len);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0x5678)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x1234, 1)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: unsupported op surfaces UnsupportedOp" {
    // With sub-h block fully closed, the remaining unsupported MVP
    // ops live in feature/ext_2_0 (e.g. memory.copy). Use one as
    // the probe.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.copy" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty, &.{}, &.{}));
}

test "compile: (i32.const 7) (i32.const 5) i32.add end → returns 12 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    // 3 vregs: vreg0 = const 7, vreg1 = const 5, vreg2 = add result.
    // vreg0 dies at pc=2 (consumed by add); vreg1 dies at pc=2;
    // vreg2 dies at pc=3 (end).
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Greedy regalloc would assign slot 0 to vreg0, slot 1 to
    // vreg1 (overlap), slot 0 again to vreg2 (vreg0 + vreg1 die
    // at the add's pc=2, so slot 0 frees AT use). Hand-supplied
    // allocation matches what greedy produces.
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / MOVZ X9 #7 / MOVZ X10 #5 / ADD X9 X9 X10 /
    //         MOV X0 X9 / LDP / RET = 8 u32s = 32 bytes.
    try testing.expectEqual(@as(usize, 56), out.bytes.len);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 7)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovzImm16(10, 5)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.sub / i32.mul / i32.and / i32.or / i32.xor / i32.shl / i32.shr_s / i32.shr_u each emit correct W-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i32.sub",   .want_word_at_offset = inst.encSubRegW(9, 9, 10) },
        .{ .op = .@"i32.mul",   .want_word_at_offset = inst.encMulRegW(9, 9, 10) },
        .{ .op = .@"i32.and",   .want_word_at_offset = inst.encAndRegW(9, 9, 10) },
        .{ .op = .@"i32.or",    .want_word_at_offset = inst.encOrrRegW(9, 9, 10) },
        .{ .op = .@"i32.xor",   .want_word_at_offset = inst.encEorRegW(9, 9, 10) },
        .{ .op = .@"i32.shl",   .want_word_at_offset = inst.encLslvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_s", .want_word_at_offset = inst.encAsrvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_u", .want_word_at_offset = inst.encLsrvRegW(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // ALU op lives at u32 offset 4 (= byte 16).
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[40..44], .little));
    }
}

test "compile: stack underflow on ALU op with 1 pushed vreg surfaces AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: i32.rotr emits single RORV W-variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotr" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Stream: STP / MOV-FP / MOVZ #FF / MOVZ #4 / RORV / MOV X0 / LDP / RET
    // = 8 u32s. RORV at byte 16.
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: i32.rotl emits 3-instr NEG-via-MOVZ-SUB + RORV sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 4 prologue+const u32s (16 bytes), expect:
    // MOVZ W16, #32  /  SUB W16, W16, W10  /  RORV W9, W9, W16
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 32)),    std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encSubRegW(16, 16, 10)),  std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 16)),   std.mem.readInt(u32, out.bytes[48..52], .little));
}

test "compile: i32 cmp ops each emit CMP + CSET with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i32.eq",   .want_cond = .eq },
        .{ .op = .@"i32.ne",   .want_cond = .ne },
        .{ .op = .@"i32.lt_s", .want_cond = .lt },
        .{ .op = .@"i32.lt_u", .want_cond = .lo },
        .{ .op = .@"i32.gt_s", .want_cond = .gt },
        .{ .op = .@"i32.gt_u", .want_cond = .hi },
        .{ .op = .@"i32.le_s", .want_cond = .le },
        .{ .op = .@"i32.le_u", .want_cond = .ls },
        .{ .op = .@"i32.ge_s", .want_cond = .ge },
        .{ .op = .@"i32.ge_u", .want_cond = .hs },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // CMP at byte 16, CSET at byte 20.
        try testing.expectEqual(@as(u32, inst.encCmpRegW(9, 10)), std.mem.readInt(u32, out.bytes[40..44], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[44..48], .little));
    }
}

test "compile: i32.clz emits direct CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9-#FF (12 bytes): CLZ W9, W9.
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: i32.ctz emits RBIT + CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9-#0x100 (12 bytes): RBIT W9, W9 / CLZ W9, W9.
    try testing.expectEqual(@as(u32, inst.encRbitW(9, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)),  std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: i32.popcnt emits 4-instr V-register SIMD pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9/MOVK-W9 (16 bytes) — 0xDEADBEEF
    // needs both lanes — the popcnt sequence starts.
    // FMOV S31, W9
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(31, 9)),     std.mem.readInt(u32, out.bytes[40..44], .little));
    // CNT V31.8B, V31.8B
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)),          std.mem.readInt(u32, out.bytes[44..48], .little));
    // ADDV B31, V31.8B
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)),         std.mem.readInt(u32, out.bytes[48..52], .little));
    // UMOV W9, V31.B[0]
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)),     std.mem.readInt(u32, out.bytes[52..56], .little));
}

test "compile: 1 local — prologue includes SUB SP,SP,#16; epilogue ADD SP,SP,#16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / SUB-SP-#16 / MOVZ W9 #7 / STR W9 [SP,#0] /
    //         LDR W9 [SP,#0] / MOV X0 X9 / ADD-SP-#16 / LDP / RET = 10 u32s = 40 bytes.
    try testing.expectEqual(@as(usize, 64), out.bytes.len);
    // Word 2: SUB SP, SP, #16.
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[32..36], .little));
    // Word 4: STR W9, [SP, #0].
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 0)),    std.mem.readInt(u32, out.bytes[40..44], .little));
    // Word 5: LDR W9, [SP, #0].
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 0)),    std.mem.readInt(u32, out.bytes[44..48], .little));
    // Word 7: ADD SP, SP, #16.
    try testing.expectEqual(@as(u32, inst.encAddImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[52..56], .little));
}

test "compile: 3 locals — frame rounds up to 32 bytes (3*8=24 → align to 32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{ .i32, .i32, .i32 };
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Word 2: SUB SP, SP, #32 (3*8=24 → aligned 32).
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 32)), std.mem.readInt(u32, out.bytes[32..36], .little));
    // local.set 2 → STR at offset 2*8=16. Word 4 (after STP/MOV-FP/SUB/MOVZ).
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 16)),   std.mem.readInt(u32, out.bytes[40..44], .little));
    // local.get 2 → LDR at offset 16. Word 5.
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 16)),   std.mem.readInt(u32, out.bytes[44..48], .little));
}

test "compile: local.tee writes to local but keeps value pushed" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    // After tee, vreg0 still on stack. end consumes it.
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Stream: STP / MOV-FP / SUB-SP / MOVZ W9 #42 / STR W9 [SP,#0] /
    //         MOV X0 X9 / ADD-SP / LDP / RET = 9 u32s = 36 bytes.
    try testing.expectEqual(@as(usize, 60), out.bytes.len);
    // Word 4: STR (the tee).
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 0)), std.mem.readInt(u32, out.bytes[40..44], .little));
    // Word 5: MOV X0, X9 (the kept-on-stack value, then end consumes it).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[44..48], .little));
}

test "compile: i64.const small value emits single MOVZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 42, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Single MOVZ X9, #42 at byte 8.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[32..36], .little));
}

test "compile: i64.const 0xCAFEBABEDEADBEEF emits MOVZ + 3 MOVK lanes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 0xCAFEBABEDEADBEEF: low_32=0xDEADBEEF, high_32=0xCAFEBABE.
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0xCAFEBABE });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // MOVZ #BEEF / MOVK #DEAD lsl 16 / MOVK #BABE lsl 32 / MOVK #CAFE lsl 48.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0xBEEF)),       std.mem.readInt(u32, out.bytes[32..36],  .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xDEAD, 1)),    std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xBABE, 2)),    std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xCAFE, 3)),    std.mem.readInt(u32, out.bytes[44..48], .little));
}

test "compile: i64.add / sub / mul / and / or / xor each emit X-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.add", .want_word_at_offset = inst.encAddReg(9, 9, 10) },
        .{ .op = .@"i64.sub", .want_word_at_offset = inst.encSubReg(9, 9, 10) },
        .{ .op = .@"i64.mul", .want_word_at_offset = inst.encMulReg(9, 9, 10) },
        .{ .op = .@"i64.and", .want_word_at_offset = inst.encAndReg(9, 9, 10) },
        .{ .op = .@"i64.or",  .want_word_at_offset = inst.encOrrReg(9, 9, 10) },
        .{ .op = .@"i64.xor", .want_word_at_offset = inst.encEorReg(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[40..44], .little));
    }
}

test "compile: i64 cmp ops each emit CMP-X + CSET-W with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i64.eq",   .want_cond = .eq },
        .{ .op = .@"i64.ne",   .want_cond = .ne },
        .{ .op = .@"i64.lt_s", .want_cond = .lt },
        .{ .op = .@"i64.lt_u", .want_cond = .lo },
        .{ .op = .@"i64.gt_s", .want_cond = .gt },
        .{ .op = .@"i64.gt_u", .want_cond = .hi },
        .{ .op = .@"i64.le_s", .want_cond = .le },
        .{ .op = .@"i64.le_u", .want_cond = .ls },
        .{ .op = .@"i64.ge_s", .want_cond = .ge },
        .{ .op = .@"i64.ge_u", .want_cond = .hs },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        try testing.expectEqual(@as(u32, inst.encCmpRegX(9, 10)),        std.mem.readInt(u32, out.bytes[40..44], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[44..48], .little));
    }
}

test "compile: i64 shifts emit X-variant LSLV/LSRV/ASRV/RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.shl",   .want_word_at_offset = inst.encLslvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_s", .want_word_at_offset = inst.encAsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_u", .want_word_at_offset = inst.encLsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.rotr",  .want_word_at_offset = inst.encRorvRegX(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[40..44], .little));
    }
}

test "compile: i64.rotl emits 3-instr X-variant NEG-via-MOVZ-#64-SUB + RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 4, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 4 prologue+const u32s (16 bytes):
    // MOVZ X16, #64 / SUB X16, X16, X10 / RORV X9, X9, X16.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 64)),    std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encSubReg(16, 16, 10)),   std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegX(9, 9, 16)),   std.mem.readInt(u32, out.bytes[48..52], .little));
}

test "compile: i64.clz emits direct CLZ X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: i64.ctz emits RBIT-X + CLZ-X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0x100, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    try testing.expectEqual(@as(u32, inst.encRbitX(9, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)),  std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: i64.popcnt emits FMOV-D + CNT/ADDV/UMOV V-register pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-X9 (12 bytes):
    // FMOV D31, X9 / CNT V31.8B / ADDV B31 / UMOV W9.
    try testing.expectEqual(@as(u32, inst.encFmovDtoFromX(31, 9)),     std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)),          std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)),         std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)),     std.mem.readInt(u32, out.bytes[48..52], .little));
}

test "compile: f32.const emits emitConstU32 + FMOV S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bits = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8 bytes): MOVZ + MOVK (lo=0x0000, hi=0x3F80)
    // — but lo=0 so just MOVK fires? No wait: emitConstU32 always
    // emits MOVZ (low 16) and conditionally MOVK (high 16). For
    // 0x3F800000: low 16 = 0x0000, high 16 = 0x3F80. MOVZ #0; MOVK
    // #0x3F80 lsl 16; FMOV S16, W9.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0)),       std.mem.readInt(u32, out.bytes[32..36],  .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x3F80, 1)), std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(16, 9)),    std.mem.readInt(u32, out.bytes[40..44], .little));
    // end with f32 result → FMOV S0, S16 = 0x1E204000 | (16<<5) = 0x1E204200.
    try testing.expectEqual(@as(u32, 0x1E204200),                     std.mem.readInt(u32, out.bytes[44..48], .little));
}

test "compile: f32 binary ALU each emits S-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f32.add", .want_word_at_offset = inst.encFAddS(16, 16, 17) },
        .{ .op = .@"f32.sub", .want_word_at_offset = inst.encFSubS(16, 16, 17) },
        .{ .op = .@"f32.mul", .want_word_at_offset = inst.encFMulS(16, 16, 17) },
        .{ .op = .@"f32.div", .want_word_at_offset = inst.encFDivS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // Each f32.const emits MOVZ + MOVK + FMOV (3 u32s = 12 bytes).
        // After STP/MOV-FP (8) + 2 consts (24) = byte 32, FP ALU fires.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[56..60], .little));
    }
}

test "compile: f32 cmps each emit FCMP-S + CSET-W with right Cond" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"f32.eq", .want_cond = .eq },
        .{ .op = .@"f32.ne", .want_cond = .ne },
        .{ .op = .@"f32.lt", .want_cond = .mi },
        .{ .op = .@"f32.gt", .want_cond = .gt },
        .{ .op = .@"f32.le", .want_cond = .ls },
        .{ .op = .@"f32.ge", .want_cond = .ge },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // FCMP at byte 32; CSET at byte 36.
        try testing.expectEqual(@as(u32, inst.encFCmpS(16, 17)),         std.mem.readInt(u32, out.bytes[56..60], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[60..64], .little));
    }
}

test "compile: f32 unary ops + min/max each emit correct encoding" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const Case = struct {
        op: zir.ZirOp,
        binary: bool,
        want_word_at_offset: u32,
    };
    const cases = [_]Case{
        .{ .op = .@"f32.abs",     .binary = false, .want_word_at_offset = inst.encFAbsS(16, 16) },
        .{ .op = .@"f32.neg",     .binary = false, .want_word_at_offset = inst.encFNegS(16, 16) },
        .{ .op = .@"f32.sqrt",    .binary = false, .want_word_at_offset = inst.encFSqrtS(16, 16) },
        .{ .op = .@"f32.ceil",    .binary = false, .want_word_at_offset = inst.encFRintPS(16, 16) },
        .{ .op = .@"f32.floor",   .binary = false, .want_word_at_offset = inst.encFRintMS(16, 16) },
        .{ .op = .@"f32.trunc",   .binary = false, .want_word_at_offset = inst.encFRintZS(16, 16) },
        .{ .op = .@"f32.nearest", .binary = false, .want_word_at_offset = inst.encFRintNS(16, 16) },
        .{ .op = .@"f32.min",     .binary = true,  .want_word_at_offset = inst.encFMinS(16, 16, 17) },
        .{ .op = .@"f32.max",     .binary = true,  .want_word_at_offset = inst.encFMaxS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        var ranges_buf: [3]zir.LiveRange = undefined;
        if (c.binary) {
            try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 2 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            ranges_buf[2] = .{ .def_pc = 2, .last_use_pc = 3 };
            try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        } else {
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 1 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        }
        f.liveness = .{ .ranges = if (c.binary) ranges_buf[0..3] else ranges_buf[0..2] };
        const slots_binary = [_]u8{ 0, 1, 0 };
        const slots_unary = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = if (c.binary)
            .{ .slots = &slots_binary, .n_slots = 2 }
        else
            .{ .slots = &slots_unary, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // After ADR-0017 prologue (STP+MOV-FP=8 + 5 LDRs + MOV
        // X19,X0 = 32 bytes per sub-2d-ii):
        // For unary: 1 const = 3 u32s (MOVZ + MOVK + FMOV S);
        //   32 + 12 = byte 44.
        // For binary: 2 consts = 6 u32s = 24 bytes;
        //   32 + 24 = byte 56.
        const op_offset: usize = if (c.binary) 56 else 44;
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[op_offset..op_offset+4][0..4], .little));
    }
}

test "compile: block + br 0 + end — forward unconditional branch fixup" {
    // (block (i32.const 7) (br 0) (i32.const 99) end (i32.const 1) end)
    // The br skips the second i32.const; the third lands as the
    // returned value (just to keep the func valid). For sub-e1
    // skeleton, just check the bytes — no execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 5 },  // dropped at br but tracked
        .{ .def_pc = 4, .last_use_pc = 5 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #7         (i32.const 7)
    // [12]  B + (forward, patched)  ← block-end fixup
    // [16]  MOVZ W9 #1         (i32.const 1, after block)
    // [20]  MOV X0, X9
    // [24]  LDP, RET ...
    //
    // Verify the B at [12] points to byte 16 (1 word forward).
    const b_word = std.mem.readInt(u32, out.bytes[36..40], .little);
    try testing.expectEqual(@as(u32, inst.encB(1)), b_word);
}

test "compile: loop + br 0 + end — backward unconditional branch" {
    // (loop (br 0) end (i32.const 1) end) — infinite-loop pattern
    // (the loop's br targets the loop's start). Verify the B's
    // disp is negative.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 3, .last_use_pc = 4 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Loop entry recorded at byte 8 (after STP/MOV-FP).
    // br targets it from byte 8 → disp = 0 words.
    // Then end (no-op for loop), then i32.const W9 #1, MOV X0, ...
    const b_word = std.mem.readInt(u32, out.bytes[32..36], .little);
    try testing.expectEqual(@as(u32, inst.encB(0)), b_word);
}

test "compile: if (i32.const N) end — single-arm if; CBZ skips to end" {
    // (i32.const 1) (if) (i32.const 7) (end) (i32.const 99) (end)
    // The if takes the cond from the const 1, and unconditionally
    // executes its then-body (i32.const 7) since 1 != 0. We're
    // testing the byte layout, not execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes if
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes function
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },  // cond
        .{ .def_pc = 2, .last_use_pc = 3 },  // then-body's const
        .{ .def_pc = 4, .last_use_pc = 5 },  // post-if
    } };
    const slots = [_]u8{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                     (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #1               (cond)
    // [12]  CBZ  W9, +2 (= byte 20)  (if-skip; patched at end)
    // [16]  MOVZ W9 #7               (then-body)
    // [20]  MOVZ W9 #99              (post-if; if's `end` lands here)
    // CBZ disp = (20 - 12) / 4 = 2.
    const cbz = std.mem.readInt(u32, out.bytes[36..40], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 2)), cbz);
}

test "compile: if/else/end — CBZ skips to else; B-uncond skips to end" {
    // (i32.const 0) (if) (i32.const 7) (else) (i32.const 99) (end) (end)
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"else" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes if
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes function
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },  // cond
        .{ .def_pc = 2, .last_use_pc = 3 },  // then-body
        .{ .def_pc = 4, .last_use_pc = 6 },  // else-body
    } };
    const slots = [_]u8{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0   (cond)
    // [12]  CBZ  W9, ?   (patched at `else` to skip then-body)
    // [16]  MOVZ W9 #7   (then-body)
    // [20]  B    ?       (skip else-body; patched at `end`)
    // [24]  MOVZ W9 #99  (else-body; CBZ patched to here)
    // [28]  ...           (if's `end` lands here; B patched to here)
    //
    // CBZ disp = (24 - 12) / 4 = 3.
    // B disp = (28 - 20) / 4 = 2.
    const cbz = std.mem.readInt(u32, out.bytes[36..40], .little);
    const b   = std.mem.readInt(u32, out.bytes[44..48], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 3)), cbz);
    try testing.expectEqual(@as(u32, inst.encB(2)),       b);
}

test "compile: i32.load — emits zero-extend + bounds-check + LDR W reg-offset + trap stub" {
    // (i32.const 8) (i32.load offset=4) end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },  // addr
        .{ .def_pc = 1, .last_use_pc = 2 },  // load result
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9 (12 bytes), the load sequence:
    //  [12]  ORR W16, WZR, W9         (zero-extend addr)
    //  [16]  ADD X16, X16, #4          (effective addr)
    //  [20]  CMP X16, X27              (bounds)
    //  [24]  B.HS  trap (placeholder + fixup)
    //  [28]  LDR W9, [X28, X16]
    try testing.expectEqual(@as(u32, inst.encOrrRegW(16, 31, 9)),  std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encAddImm12(16, 16, 4)), std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(16, 27)),     std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encLdrWReg(9, 28, 16)),  std.mem.readInt(u32, out.bytes[52..56], .little));
    // Trap stub starts AFTER MOV X0/LDP/RET. Per sub-7.5b-ii,
    // the stub now is: MOVZ W17,#1 + STR W17,[X19,#trap_flag_off]
    // + MOVZ X0,#0 + (epilogue) LDP + RET.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(17, 1)),    std.mem.readInt(u32, out.bytes[68..72], .little));
    // B.HS placeholder is patched to point at the trap stub start.
    const bhs_patched = std.mem.readInt(u32, out.bytes[48..52], .little);
    // The exact disp depends on byte layout; verify the cond field
    // is .hs (low 4 bits == 0x2) and the placeholder is now a
    // valid B.cond instruction.
    try testing.expectEqual(@as(u32, 0x2), bhs_patched & 0xF);
    try testing.expectEqual(@as(u32, 0x54000000), bhs_patched & 0xFF000010);
}

test "compile: memory ops dispatch correctly per variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_load_word: u32 }{
        .{ .op = .@"i32.load8_u",  .want_load_word = inst.encLdrbWReg(9, 28, 16) },
        .{ .op = .@"i32.load8_s",  .want_load_word = inst.encLdrsbWReg(9, 28, 16) },
        .{ .op = .@"i32.load16_u", .want_load_word = inst.encLdrhWReg(9, 28, 16) },
        .{ .op = .@"i32.load16_s", .want_load_word = inst.encLdrshWReg(9, 28, 16) },
        .{ .op = .@"i64.load",     .want_load_word = inst.encLdrXReg(9, 28, 16) },
        .{ .op = .@"i64.load8_s",  .want_load_word = inst.encLdrsbXReg(9, 28, 16) },
        .{ .op = .@"i64.load16_s", .want_load_word = inst.encLdrshXReg(9, 28, 16) },
        .{ .op = .@"i64.load32_s", .want_load_word = inst.encLdrswXReg(9, 28, 16) },
        .{ .op = .@"i64.load32_u", .want_load_word = inst.encLdrWReg(9, 28, 16) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // Stream: STP/MOV-FP (8) + MOVZ W9 (4) + ORR W16 (4) +
        // (offset==0 → no ADD) + CMP (4) + B.HS (4) = byte 24 for the LDR.
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[48..52], .little));
    }
}

test "compile: f32.load + f64.load dispatch to S/D-form LDR" {
    const sig_s: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const sig_d: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    const cases = [_]struct { op: zir.ZirOp, sig: zir.FuncType, want_load_word: u32 }{
        .{ .op = .@"f32.load", .sig = sig_s, .want_load_word = inst.encLdrSReg(16, 28, 16) },
        .{ .op = .@"f64.load", .sig = sig_d, .want_load_word = inst.encLdrDReg(16, 28, 16) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, c.sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[48..52], .little));
    }
}

test "compile: memory.size emits LSR W_dest, W27, #16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.size" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8 bytes), LSR fires.
    try testing.expectEqual(@as(u32, inst.encLsrImmW(9, 27, 16)), std.mem.readInt(u32, out.bytes[32..36], .little));
}

test "compile: memory.grow emits MOVN W_dest, #0 (skeleton return -1)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });   // delta
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.grow" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // STP/MOV-FP (8) + MOVZ W9 #1 (4) + MOVN W9 (4) at byte 12.
    try testing.expectEqual(@as(u32, inst.encMovnImmW(9, 0)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: i32.store — emits bounds-check + STR W reg-offset" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });   // addr
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });  // value
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store", .payload = 0 });   // offset = 0
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Stream:
    //  [0]  STP / MOV-FP                      (8 bytes)
    //  [8]  MOVZ W9 #8                         (addr)
    // [12]  MOVZ W10 #42                       (value)
    // [16]  ORR W16, WZR, W9                   (zero-extend addr)
    // (offset == 0, no ADD)
    // [20]  CMP X16, X27
    // [24]  B.HS trap (fixup)
    // [28]  STR W10, [X28, X16]
    // [32]  LDP / RET / trap stub ...
    try testing.expectEqual(@as(u32, inst.encOrrRegW(16, 31, 9)), std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(16, 27)),    std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encStrWReg(10, 28, 16)), std.mem.readInt(u32, out.bytes[52..56], .little));
}

test "compile: br_table — emits CMP+B.NE+B chain + default B" {
    // (block               ; outer block 1 (depth 1)
    //   (block             ; inner block 0 (depth 0)
    //     (i32.const 0)    ; index value
    //     (br_table 0 1)   ; case 0 → depth 0, default → depth 1
    //     (i32.const 7)    ; never reached
    //   end)               ; inner end
    //   (i32.const 99)
    // end)                 ; outer end
    // (i32.const 1) (end)  ; func end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Build branch_targets: [0, 1] — case 0 → 0, default → 1.
    try f.branch_targets.append(testing.allocator, 0);
    try f.branch_targets.append(testing.allocator, 1);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_table", .payload = 1, .extra = 0 }); // count=1, start=0
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // inner block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // outer block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // func end
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 2, .last_use_pc = 3 },  // index
        .{ .def_pc = 5, .last_use_pc = 6 },  // post-inner block
        .{ .def_pc = 7, .last_use_pc = 8 },  // post-outer block
    } };
    const slots = [_]u8{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0      (index)
    // [12]  CMP W9, #0       (br_table case 0 cmp)
    // [16]  B.NE +2          (skip the next B if not equal)
    // [20]  B  ?             (forward fixup → inner-block end target)
    // [24]  B  ?             (forward fixup → outer-block end / default)
    // [28]  MOVZ W9 #99       ← inner-block-end target lands here
    // [32]  MOVZ W9 #1        ← outer-block-end target lands here
    // CMP at byte 12; B.NE at 16; case-0 B at 20 → +2 = byte 28; default B at 24 → +2 = byte 32.
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)),  std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encBCond(.ne, 2)),  std.mem.readInt(u32, out.bytes[40..44], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)),           std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)),           std.mem.readInt(u32, out.bytes[48..52], .little));
}

test "compile: br_if 0 — forward CBNZ fixup" {
    // (block (i32.const 0) (br_if 0) (i32.const 7) end (i32.const 1) end)
    // br_if 0 reads the cond (0 → no branch, continues to const 7).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_if", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 3, .last_use_pc = 5 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0         (i32.const 0 → the cond)
    // [12]  CBNZ W9, +2        (br_if; patched to skip past const 7 → end of block)
    // [16]  MOVZ W9 #7         (i32.const 7)
    // [20]  block end → target lands here
    // CBNZ disp_words = (20 - 12) / 4 = 2.
    const cbnz = std.mem.readInt(u32, out.bytes[36..40], .little);
    try testing.expectEqual(@as(u32, inst.encCbnzW(9, 2)), cbnz);
}

test "compile: f32.copysign emits 8-instr FMOV/BIC/AND/ORR sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.5f magnitude src + (-2.0f) sign src → expect -1.5f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3FC00000 });  // 1.5
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xC0000000 });  // -2.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8) + 2 consts (each 3 u32s = 24) = byte 32.
    // Then 8 copysign instrs.
    // [32]: MOVZ X16, #0
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 0)),       std.mem.readInt(u32, out.bytes[56..60], .little));
    // [36]: MOVK X16, #0x8000, lsl #16
    try testing.expectEqual(@as(u32, inst.encMovkImm16(16, 0x8000, 1)), std.mem.readInt(u32, out.bytes[60..64], .little));
    // [40]: FMOV W9, S16  (W_a from S_x at slot[result]=0 → V16)
    try testing.expectEqual(@as(u32, inst.encFmovWFromS(9, 16)),       std.mem.readInt(u32, out.bytes[64..68], .little));
    // [44]: BIC W9, W9, W16
    try testing.expectEqual(@as(u32, inst.encBicRegW(9, 9, 16)),       std.mem.readInt(u32, out.bytes[68..72], .little));
    // [48]: FMOV W17, S17  (W17 from S_y at slot[rhs]=1 → V17)
    try testing.expectEqual(@as(u32, inst.encFmovWFromS(17, 17)),      std.mem.readInt(u32, out.bytes[72..76], .little));
    // [52]: AND W17, W17, W16
    try testing.expectEqual(@as(u32, inst.encAndRegW(17, 17, 16)),     std.mem.readInt(u32, out.bytes[76..80], .little));
    // [56]: ORR W9, W9, W17
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 9, 17)),       std.mem.readInt(u32, out.bytes[80..84], .little));
    // [60]: FMOV S16, W9
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(16, 9)),     std.mem.readInt(u32, out.bytes[84..88], .little));
}

test "compile: f64.copysign emits X-form 8-instr sequence with hw=3 mask" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.5 + (-2.0) f64
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF80000 });  // 1.5
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0xC0000000 });  // -2.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // f64.const 1.5: bits=0x3FF8000000000000. Lanes: l0=0,l1=0,
    // l2=0,l3=0x3FF8. Only l3 nonzero → MOVZ + MOVK lane3 + FMOV D
    // = 3 u32s. Same shape for -2.0. After STP/MOV-FP (8) + 6 u32s
    // (24) = byte 32.
    // [32]: MOVZ X16, #0
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 0)),       std.mem.readInt(u32, out.bytes[56..60], .little));
    // [36]: MOVK X16, #0x8000, lsl #48
    try testing.expectEqual(@as(u32, inst.encMovkImm16(16, 0x8000, 3)), std.mem.readInt(u32, out.bytes[60..64], .little));
    // [40]: FMOV X9, D16
    try testing.expectEqual(@as(u32, inst.encFmovXFromD(9, 16)),      std.mem.readInt(u32, out.bytes[64..68], .little));
    // [44]: BIC X9, X9, X16
    try testing.expectEqual(@as(u32, inst.encBicRegX(9, 9, 16)),      std.mem.readInt(u32, out.bytes[68..72], .little));
    // [48]: FMOV X17, D17
    try testing.expectEqual(@as(u32, inst.encFmovXFromD(17, 17)),     std.mem.readInt(u32, out.bytes[72..76], .little));
    // [52]: AND X17, X17, X16
    try testing.expectEqual(@as(u32, inst.encAndReg(17, 17, 16)),     std.mem.readInt(u32, out.bytes[76..80], .little));
    // [56]: ORR X9, X9, X17
    try testing.expectEqual(@as(u32, inst.encOrrReg(9, 9, 17)),       std.mem.readInt(u32, out.bytes[80..84], .little));
    // [60]: FMOV D16, X9
    try testing.expectEqual(@as(u32, inst.encFmovDtoFromX(16, 9)),    std.mem.readInt(u32, out.bytes[84..88], .little));
}

test "compile: f64 binary ALU each emits D-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f64.add", .want_word_at_offset = inst.encFAddD(16, 16, 17) },
        .{ .op = .@"f64.sub", .want_word_at_offset = inst.encFSubD(16, 16, 17) },
        .{ .op = .@"f64.mul", .want_word_at_offset = inst.encFMulD(16, 16, 17) },
        .{ .op = .@"f64.div", .want_word_at_offset = inst.encFDivD(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        // 1.0 + 2.0 (f64 bits): payload = lo32, extra = hi32.
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x3FF00000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // f64.const 1.0: bits=0x3FF0000000000000. Lanes: lo=0, l1=0,
        // l2=0, l3=0x3FF0. Only lane 3 nonzero (besides lane 0).
        // So const emits MOVZ + MOVK lane3 + FMOV D = 3 u32s.
        // f64.const 2.0: bits=0x4000000000000000. Lane 3 = 0x4000.
        // Same shape.
        // After STP/MOV-FP (8) + 2 consts (24) = byte 32, ALU fires.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[56..60], .little));
    }
}

test "compile: i64.eqz emits CMP-X-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    try testing.expectEqual(@as(u32, inst.encCmpImmX(9, 0)),    std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)),    std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: function with non-empty params surfaces UnsupportedOp" {
    const params = [_]zir.ValType{.i32};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty, &.{}, &.{}));
}

test "compile: i32.eqz emits CMP-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9-#0 (12 bytes): CMP W9,#0 / CSET W9,EQ.
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)),   std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)),   std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: call N (no-arg skeleton) emits BL placeholder + records fixup + result MOV W_dest, W0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // call func_idx = 7 — a forward callee whose body offset isn't
    // known to compile(); the post-emit linker patches the BL via
    // EmitOutput.call_fixups.
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    // func_sigs[7] = i32-returning, no args.
    var sigs: [8]zir.FuncType = undefined;
    for (&sigs) |*s| s.* = .{ .params = &.{}, .results = &.{} };
    sigs[7] = .{ .params = &.{}, .results = &.{ .i32 } };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);

    // Layout after prologue (32 bytes per ADR-0017 sub-2d-ii):
    //   [32..36] ORR X0, XZR, X19  (restore runtime_ptr)
    //   [36..40] BL 0               (placeholder; fixup recorded)
    //   [40..44] ORR W9, WZR, W0    (MOV W9, W0 — capture i32 result)
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[32..36], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)), std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)), std.mem.readInt(u32, out.bytes[40..44], .little));

    // One fixup recorded with byte_offset = 36 (after prologue + MOV X0,X19)
    // + target_func_idx = 7.
    try testing.expectEqual(@as(usize, 1), out.call_fixups.len);
    try testing.expectEqual(@as(u32, 36), out.call_fixups[0].byte_offset);
    try testing.expectEqual(@as(u32, 7), out.call_fixups[0].target_func_idx);
}

test "compile: call N — i64 callee result captured via X-form ORR" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{ .{ .params = &.{}, .results = &.{ .i64 } } };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);
    // After prologue (32) + MOV X0,X19 (4) + BL (4) = 40:
    //   [40..44] ORR X9, XZR, X0 (X-form for i64).
    try testing.expectEqual(@as(u32, inst.encOrrReg(9, 31, 0)), std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: call N — f32 callee result captured via FMOV S, S0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{ .{ .params = &.{}, .results = &.{ .f32 } } };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);
    // After prologue (32) + MOV X0,X19 (4) + BL (4) = 40:
    //   [40..44] FMOV S16, S0 (f32 slot 0 → V16).
    try testing.expectEqual(@as(u32, inst.encFmovSReg(16, 0)), std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: call N — i32 + i64 args marshalled into W1/X2 (X0=runtime ptr per ADR-0017), result in W0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // (i32.const 7) (i64.const 0xDEADBEEF) call 0  ; callee: (i32, i64) → i32
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 }, // arg0 i32 → slot 0
        .{ .def_pc = 1, .last_use_pc = 2 }, // arg1 i64 → slot 1
        .{ .def_pc = 2, .last_use_pc = 3 }, // result   → slot 0 (reuses)
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .i32, .i64 }, .results = &.{ .i32 } },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);

    // Layout (bytes, post-ADR-0017 prologue = 32, sub-2d-ii):
    //   [32..36]  MOVZ W9, #7               ; arg0 → slot 0 → X9
    //   [36..40]  MOVZ X10, #0xBEEF         ; arg1 lo16
    //   [40..44]  MOVK X10, #0xDEAD lsl#16  ; arg1 hi16
    //   [44..48]  ORR W1, WZR, W9           ; marshal arg0 i32 → W1
    //   [48..52]  ORR X2, XZR, X10          ; marshal arg1 i64 → X2
    //   [52..56]  ORR X0, XZR, X19          ; restore runtime_ptr
    //   [56..60]  BL 0                      ; call placeholder
    //   [60..64]  ORR W9, WZR, W0           ; capture i32 result
    try testing.expectEqual(@as(u32, inst.encOrrRegW(1, 31, 9)), std.mem.readInt(u32, out.bytes[44..48], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(2, 31, 10)), std.mem.readInt(u32, out.bytes[48..52], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[52..56], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)),             std.mem.readInt(u32, out.bytes[56..60], .little));
}

test "compile: call N — f32 + f64 args marshalled into S0/D1" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // f32.const + f64.const + call 0 ; callee: (f32, f64) → f32
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 }); // 2.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 }); // 3.0
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .f32, .f64 }, .results = &.{ .f32 } },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);
    // The two arg-marshal MOVs land just before the BL: search the
    // tail for FMOV S0, S16 + FMOV D1, D17 + BL 0.
    // These are stable within the byte stream irrespective of how
    // the const-load prologue lays out — we locate the BL and walk
    // backwards.
    var bl_off: usize = 0;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == inst.encBL(0)) {
            bl_off = p;
            break;
        }
    }
    try testing.expect(bl_off >= 12);
    // Layout immediately before BL (post-sub-2d-ii):
    //   [bl_off-12] FMOV S0, S16     ; arg0
    //   [bl_off-8]  FMOV D1, D17     ; arg1
    //   [bl_off-4]  ORR X0, XZR, X19 ; restore runtime_ptr
    try testing.expectEqual(@as(u32, inst.encFmovSReg(0, 16)), std.mem.readInt(u32, out.bytes[bl_off - 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovDReg(1, 17)), std.mem.readInt(u32, out.bytes[bl_off - 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[bl_off - 4 ..][0..4], .little));
}

test "compile: call N — void callee pushes no result vreg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const sigs = [_]zir.FuncType{ .{ .params = &.{}, .results = &.{} } };
    const out = try compile(testing.allocator, &f, empty, &sigs, &.{});
    defer deinit(testing.allocator, out);
    // Layout: prologue (32) + MOV X0,X19 (4) + BL (4) = 40,
    // then epilogue (LDP+RET = 8). Bytes len = 48.
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[32..36], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: call_indirect — bounds (CMP/B.HS) + sig (LDR/CMP/B.NE) + funcptr (LDR-LSL3/BLR)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 3, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    // module_types[3] is what `call_indirect type_idx=3` consults.
    var types: [4]zir.FuncType = undefined;
    for (&types) |*t| t.* = .{ .params = &.{}, .results = &.{} };
    types[3] = .{ .params = &.{}, .results = &.{ .i32 } };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &types);
    defer deinit(testing.allocator, out);

    // Layout (post-sub-2d-ii prologue=32):
    //   [32..36] MOVZ W9, #5                   ; idx const
    //   [36..40] ORR W17, WZR, W9              ; zero-extend idx
    //   [40..44] CMP W17, W25                  ; bounds
    //   [44..48] B.HS trap_stub                ; placeholder
    //   [48..52] LDR W16, [X24, X17, LSL #2]   ; sig load
    //   [52..56] CMP W16, #3                   ; sig compare
    //   [56..60] B.NE trap_stub                ; placeholder
    //   [60..64] LDR X17, [X26, X17, LSL #3]   ; funcptr
    //   [64..68] ORR X0, XZR, X19              ; restore runtime_ptr
    //   [68..72] BLR X17
    //   [72..76] ORR W9, WZR, W0               ; capture
    try testing.expectEqual(@as(u32, inst.encOrrRegW(17, 31, 9)),       std.mem.readInt(u32, out.bytes[36..40], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegW(17, 25)),          std.mem.readInt(u32, out.bytes[40..44], .little));
    const bhs = std.mem.readInt(u32, out.bytes[44..48], .little);
    try testing.expectEqual(@as(u32, 0x2), bhs & 0xF); // cond=.hs
    try testing.expectEqual(@as(u32, inst.encLdrWRegLsl2(16, 24, 17)),  std.mem.readInt(u32, out.bytes[48..52], .little));
    try testing.expectEqual(@as(u32, inst.encCmpImmW(16, 3)),           std.mem.readInt(u32, out.bytes[52..56], .little));
    const bne = std.mem.readInt(u32, out.bytes[56..60], .little);
    try testing.expectEqual(@as(u32, 0x1), bne & 0xF); // cond=.ne
    try testing.expectEqual(@as(u32, inst.encLdrXRegLsl3(17, 26, 17)),  std.mem.readInt(u32, out.bytes[60..64], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[64..68], .little));
    try testing.expectEqual(@as(u32, inst.encBLR(17)),                  std.mem.readInt(u32, out.bytes[68..72], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)),        std.mem.readInt(u32, out.bytes[72..76], .little));
}

test "compile: i32.wrap_i64 emits MOV W,W (= ORR W, WZR, W)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xCAFE, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8) + MOVZ X9, #0xCAFE (4) = 12 bytes:
    //   [12..16] ORR W9, WZR, W9 (in-place wrap; valid no-op MOV)
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: i64.extend_i32_s emits SXTW X, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After [8..16] MOVZ + MOVK to load 0xFFFFFFFF into W9 (8 bytes):
    //   [16..20] SXTW X9, W9
    try testing.expectEqual(@as(u32, inst.encSxtw(9, 9)), std.mem.readInt(u32, out.bytes[40..44], .little));
}

test "compile: i64.extend_i32_u emits MOV W,W (zero-extends via W-write)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8) + MOVZ W9, #42 (4) = 12 bytes:
    //   [12..16] ORR W9, WZR, W9
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: f32.convert_i32_s emits SCVTF S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8) + MOVZ W9, #7 (4) = 12 bytes:
    //   [12..16] SCVTF S16, W9 (slot 0 → V16 dest, X9 src)
    try testing.expectEqual(@as(u32, inst.encScvtfSFromW(16, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: f64.convert_i64_u emits UCVTF D, X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEAD, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.convert_i64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8) + MOVZ X9, #0xDEAD (4) = 12 bytes (single hi16==0):
    //   [12..16] UCVTF D16, X9
    try testing.expectEqual(@as(u32, inst.encUcvtfDFromX(16, 9)), std.mem.readInt(u32, out.bytes[36..40], .little));
}

test "compile: f32.demote_f64 emits FCVT S, D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.demote_f64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Find FCVT S16, D16 in the byte stream.
    const expected = inst.encFcvtSFromD(16, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: f64.promote_f32 emits FCVT D, S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.promote_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFcvtDFromS(16, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.trunc_sat_f32_s emits FCVTZS W, S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFcvtzsWFromS(9, 16); // dest W9, src V16
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i64.trunc_sat_f64_u emits FCVTZU X, D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFcvtzuXFromD(9, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.reinterpret_f32 emits FMOV W, S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.reinterpret_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFmovWFromS(9, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: f64.reinterpret_i64 emits FMOV D, X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xCAFE, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.reinterpret_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFmovDtoFromX(16, 9);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.trunc_f32_s emits NaN+lower+upper checks then FCVTZS W,S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected core instructions to find in the byte stream:
    //   FCMP S16, S16   ; NaN check
    //   FMOV S31, W16   ; bound stage (×2 — once each for lower/upper)
    //   FCMP S16, S31   ; bound compare (×2)
    //   FCVTZS W9, S16  ; the conversion
    //
    // We walk the stream and verify each appears in expected
    // order; trap-branch placeholders share encoding shape with
    // existing bounds-check tests, so we don't re-verify their
    // raw bytes here (covered by the trap-stub patching test).
    var found_fcmp_self = false;
    var found_fcvtzs = false;
    var fcmp_self_count: u32 = 0;
    var fcmp_v31_count: u32 = 0;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == inst.encFCmpS(16, 16)) {
            found_fcmp_self = true;
            fcmp_self_count += 1;
        }
        if (w == inst.encFCmpS(16, 31)) fcmp_v31_count += 1;
        if (w == inst.encFcvtzsWFromS(9, 16)) found_fcvtzs = true;
    }
    try testing.expect(found_fcmp_self);
    try testing.expectEqual(@as(u32, 1), fcmp_self_count);  // NaN check is single FCMP self
    try testing.expectEqual(@as(u32, 2), fcmp_v31_count);  // 2 bound checks
    try testing.expect(found_fcvtzs);
}

test "compile: i32.trunc_f64_s emits NaN+f64-lower+f64-upper checks then FCVTZS W,D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f64_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Walk the byte stream looking for the D-form NaN check + 2
    // bounds compares + final FCVTZS.
    var fcmp_self_count: u32 = 0;
    var fcmp_v31_count: u32 = 0;
    var found_fcvtzs = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == inst.encFCmpD(16, 16)) fcmp_self_count += 1;
        if (w == inst.encFCmpD(16, 31)) fcmp_v31_count += 1;
        if (w == inst.encFcvtzsWFromD(9, 16)) found_fcvtzs = true;
    }
    try testing.expectEqual(@as(u32, 1), fcmp_self_count);
    try testing.expectEqual(@as(u32, 2), fcmp_v31_count);
    try testing.expect(found_fcvtzs);
}

test "compile: ADR-0018 sub-1c — i32.const into spilled vreg, full round-trip via STR + LDR" {
    // Force vreg 0 into spill territory (slot 10). The frame
    // extends by spillBytes() = 8; spill base offset = 0
    // (no locals). i32.const handler emits MOVZ X14 #42 + STR
    // X14, [SP, #0]. end handler emits LDR X14, [SP, #0] + MOV
    // X0, X14. Inspect bytes for these key instructions.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{10};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots = 10,
    };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Bytes contain (in order): STP+MOVfp + SUB sp,#16 (frame
    // rounded up to 16) + MOVZ X14,#42 + STR X14,[SP] + ORR X0,XZR,X14
    // + ADD sp,#16 + LDP + RET.
    const expected_movz = inst.encMovzImm16(14, 42);
    const expected_str = inst.encStrImm(14, 31, 0);
    const expected_ldr_at_end = inst.encLdrImm(14, 31, 0);

    var saw_movz = false;
    var saw_str = false;
    var saw_ldr_at_end = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == expected_movz) saw_movz = true;
        if (w == expected_str) saw_str = true;
        if (w == expected_ldr_at_end) saw_ldr_at_end = true;
    }
    try testing.expect(saw_movz);
    try testing.expect(saw_str);
    try testing.expect(saw_ldr_at_end);
}

test "compile: ADR-0018 — slot 9 = last reg (X23), slot 10 = first spill" {
    const slots_9 = [_]u8{9};
    const alloc_reg: regalloc.Allocation = .{
        .slots = &slots_9,
        .n_slots = 10,
        .max_reg_slots = 10,
    };
    try testing.expectEqual(regalloc.Slot{ .reg = 9 }, alloc_reg.slot(0));

    const slots_10 = [_]u8{10};
    const alloc_spill: regalloc.Allocation = .{
        .slots = &slots_10,
        .n_slots = 11,
        .max_reg_slots = 10,
    };
    try testing.expectEqual(regalloc.Slot{ .spill = 0 }, alloc_spill.slot(0));
}

comptime {
    _ = liveness_mod; // hook upstream module so future regalloc tests are reachable
}
