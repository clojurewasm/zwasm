//! x86_64 emit pass — skeleton (§9.7 / 7.7).
//!
//! Mirrors the role of `arm64/emit.zig`'s `compile()` entry but
//! covers the minimal `(i32.const N) end` cycle to prove the
//! ZIR → x86_64 byte-stream pipeline end-to-end. Subsequent
//! chunks layer on op coverage (i32 ALU, memory, control flow,
//! calls, FP) and the reserved_invariant_gprs reservation
//! decision (deferred from §9.7 / 7.6 chunk c).
//!
//! Skeleton scope (this commit):
//! - Function prologue: PUSH RBP ; MOV RBP, RSP (no SUB RSP yet
//!   — locals + spills land with the regalloc port).
//! - `i32.const N` → MOV r32(slot 0), #N (zero-extended to 64 by
//!   the W-form of MOV-imm).
//! - Function-level `end` → MOV EAX, r32(top vreg) ; POP RBP ;
//!   RET. EAX is RAX low 32 bits — Wasm i32 return per SysV
//!   x86_64 §3.2.4.
//!
//! What's INTENTIONALLY NOT in this skeleton:
//! - Multi-call X0-style runtime_ptr restore: arm64's ADR-0017
//!   sub-2d-ii doesn't apply here yet because there are no
//!   calls. The reserved_invariant_gprs decision (load-once at
//!   prologue vs reload-from-runtime-ptr at point of use) lands
//!   when the first call / memory op handler arrives.
//! - Frame extension for locals / spills (no LOCAL ops in the
//!   skeleton — `func.locals.len > 0` → `UnsupportedOp`).
//! - Call fixups (no `call` ops — `EmitOutput.call_fixups` is
//!   declared but always empty in this chunk).
//! - Bounds-check trap stub (no memory ops yet).
//! - Label / control flow stack (no `block` / `loop` / `br`
//!   / `if` ops).
//!
//! The shape mirrors arm64/emit.zig (compile() returns
//! EmitOutput; `func.liveness` must agree with `alloc.slots`)
//! so the §9.7 / 7.11 three-way differential can compare ARM64
//! and x86_64 outputs at the same byte-stream layer.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");
const label_mod = @import("label.zig");
const op_alu_int = @import("op_alu_int.zig");
const op_alu_float = @import("op_alu_float.zig");
const op_convert = @import("op_convert.zig");
const op_memory = @import("op_memory.zig");
const op_control = @import("op_control.zig");
const op_call = @import("op_call.zig");
const op_globals = @import("op_globals.zig");
const gpr = @import("gpr.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;

// Re-exports from `types.zig` (D-030 chunk-a) — external callers
// (`src/zwasm.zig`, `src/diagnostic/trace.zig`, the linker) and
// the inner emit-pass code keep referencing these via the original
// `x86_64/emit.zig` paths.
pub const Error = types.Error;
pub const CallFixup = types.CallFixup;
pub const EmitOutput = types.EmitOutput;
pub const deinit = types.deinit;

// Internal types from `label.zig` (D-030 chunk-a). Aliased so the
// dispatch loop body keeps reading like the pre-split code.
const LabelKind = label_mod.LabelKind;
const Fixup = label_mod.Fixup;
const Label = label_mod.Label;

/// Emit x86_64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here). `func_sigs` and `module_types` are
/// declared for shape-parity with arm64 but unused in this
/// skeleton (no `call` / `call_indirect` handlers yet).
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
    // §9.7 / 7.8-x86-params: lift the params=0 reject. Mirrors
    // arm64/emit.zig:134 ("Multi-arg entry"). For now i32-only
    // params are supported; i64/f32/f64 surface UnsupportedOp
    // until the type-aware local + FP-marshal chunks land.
    // SysV reserves RDI for the runtime ptr (ADR-0026), so user
    // int args start at RSI (max 5). Win64 reserves RCX → user
    // int args start at RDX (max 3). The total runs through the
    // arch-specific `abi.current.arg_gprs` array, indexed past
    // the runtime-ptr save reg.
    const num_params: u32 = @intCast(func.sig.params.len);
    for (func.sig.params) |p| {
        switch (p) {
            .i32, .i64, .f32, .f64 => {},
            .v128, .funcref, .externref => {
                std.debug.print("x86_64/emit: param type `{s}` unsupported (func_idx={d})\n", .{ @tagName(p), func.func_idx });
                return Error.UnsupportedOp;
            },
        }
    }
    const num_locals: u32 = @intCast(func.locals.len);
    const total_locals: u32 = num_params + num_locals;
    // localDisp's i8 disp limits: with uses_runtime_ptr the deepest
    // slot lives at -8 - 8*total_locals which must stay >= -128 →
    // total_locals <= 15. Without uses_runtime_ptr the cap is
    // total_locals <= 16.
    if (total_locals > 15) return Error.UnsupportedOp;

    // Prescan: does this function need the runtime-ptr save?
    // Per ADR-0026, memory ops (and future calls / call_indirect)
    // require RDI captured into R15 at function entry. Functions
    // that don't touch memory or make calls keep the simpler 1-PUSH
    // prologue, preserving backward-compat with the existing skel
    // / ALU / control tests.
    // **Same-class grep target**: i64 / f32 / f64 memory ops will
    // be added to BOTH this prescan AND emitMemOp's `access_size`
    // switch + dispatch arm in `body switch` simultaneously. Forgetting
    // either one leads to "uses_runtime_ptr=false but R15 referenced"
    // class bugs (silent invalid instruction stream). See D-030 for
    // the planned discharge timing (post-7.7 op surface completion).
    const uses_runtime_ptr = blk: {
        for (func.instrs.items) |ins| {
            switch (ins.op) {
                .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
                .@"i32.load16_s", .@"i32.load16_u",
                .@"i32.store", .@"i32.store8", .@"i32.store16",
                .@"i64.load", .@"i64.load8_s", .@"i64.load8_u",
                .@"i64.load16_s", .@"i64.load16_u",
                .@"i64.load32_s", .@"i64.load32_u",
                .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
                .@"f32.load", .@"f64.load",
                .@"f32.store", .@"f64.store",
                .@"global.get", .@"global.set",
                .@"memory.size", .@"memory.grow",
                .@"call",
                .@"call_indirect",
                => break :blk true,
                else => {},
            }
        }
        break :blk false;
    };

    // Frame-bytes formula depends on prologue shape (SysV §3.2.2
    // 16-byte stack alignment; CALL pushes ret addr → entry RSP
    // ≡ 8 mod 16; PUSH RBP → 0 mod 16; PUSH R15 → 8 mod 16):
    //   - 1-PUSH:  frame ≡ 0 mod 16  (current shape; rounds up locals_bytes to 16)
    //   - 2-PUSH:  frame ≡ 8 mod 16  (per ADR-0026 prologue)
    //
    // D-045 chunk 13b: extend frame by spill region. Layout
    // (frame grows DOWN from RBP):
    //   [RBP - 8]                     R15 save (if uses_runtime_ptr)
    //   [RBP - 8*(K+1)]               local K  (without R15)
    //   [RBP - 8 - 8*(K+1)]           local K  (with R15)
    //   [RBP - spill_base_off - off]  spill slot at offset `off`
    // `spill_base_off` = locals_bytes + (uses_runtime_ptr ? 8 : 0) + 8
    // (the +8 puts spill slot 0 in the next 8-byte cell below
    // the deepest local). `gpr.zig`'s `rbpDispNegI8` consumes it
    // as `disp = -(spill_base_off + spill_off)`.
    const locals_bytes: u32 = total_locals * 8;
    const spill_bytes: u32 = alloc.spillBytes();
    const r15_save_bytes: u32 = if (uses_runtime_ptr) 8 else 0;
    const spill_base_off: u32 = locals_bytes + r15_save_bytes + 8;
    const frame_unaligned: u32 = locals_bytes + spill_bytes;
    const frame_bytes: u32 = if (uses_runtime_ptr)
        ((frame_unaligned + 7) & ~@as(u32, 15)) + 8
    else
        (frame_unaligned + 15) & ~@as(u32, 15);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Prologue:
    //   PUSH RBP
    //   PUSH R15           (only if uses_runtime_ptr; saves callee-saved R15)
    //   MOV RBP, RSP       (frame pointer captured AFTER any extra push)
    //   MOV R15, RDI       (only if uses_runtime_ptr; capture runtime_ptr arg)
    //   SUB RSP, frame_bytes
    //
    // Local layout (Wasm ZirFunc.locals): local K at
    //   [RBP - 8*(K+1)]               when !uses_runtime_ptr
    //   [RBP - 8 - 8*(K+1)]           when  uses_runtime_ptr (R15 occupies [RBP-8])
    try buf.appendSlice(allocator, inst.encPushR(.rbp).slice());
    if (uses_runtime_ptr) {
        try buf.appendSlice(allocator, inst.encPushR(.r15).slice());
    }
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rbp, .rsp).slice());
    if (uses_runtime_ptr) {
        // MOV R15, <entry_arg0> — entry shim's runtime_ptr snapshot.
        // Cc-pivot per ADR-0026: SysV passes *const JitRuntime in
        // RDI; Win64 in RCX. Both encodings are 3 bytes (REX.W+B
        // + opcode + modrm) so the prologue's frame-bytes formula
        // stays Cc-agnostic.
        try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, abi.current.entry_arg0_gpr).slice());
    }
    if (frame_bytes > 0) {
        // `encSubRSpImm8` is i8-bounded (≤ 127). With spill slots
        // a function can exceed that; surface as SlotOverflow
        // until chunk 13c adds the imm32 form.
        if (frame_bytes > 127) return Error.SlotOverflow;
        try buf.appendSlice(allocator, inst.encSubRSpImm8(@intCast(frame_bytes)).slice());
    }

    // §9.7 / 7.8-x86-params: marshal i32 params from arg regs to
    // local slots. Per ADR-0026 Cc-pivot:
    //   SysV: arg_gprs = {RDI, RSI, RDX, RCX, R8, R9}; RDI = runtime
    //         ptr, user int args from RSI (max 5)
    //   Win64: arg_gprs = {RCX, RDX, R8, R9}; RCX = runtime ptr,
    //         user int args from RDX (max 3)
    // The base index into arg_gprs is set so index 0 of the user
    // params lands on the first non-runtime-ptr arg reg.
    const base_off_for_locals: i8 = if (uses_runtime_ptr) -8 else 0;
    {
        var p_idx: u32 = 0;
        var int_arg_idx: usize = 1; // skip runtime_ptr_gpr (= arg_gprs[0])
        var fp_arg_idx: usize = 0;
        while (p_idx < num_params) : (p_idx += 1) {
            const off_i32: i32 = @as(i32, base_off_for_locals) - @as(i32, @intCast((p_idx + 1) * 8));
            if (off_i32 < -128) return Error.UnsupportedOp;
            const off: i8 = @intCast(off_i32);
            switch (func.sig.params[p_idx]) {
                .i32 => {
                    if (int_arg_idx >= abi.current.arg_gprs.len) {
                        return Error.UnsupportedOp;
                    }
                    try buf.appendSlice(allocator, inst.encStoreR32MemRBP(off, abi.current.arg_gprs[int_arg_idx]).slice());
                    int_arg_idx += 1;
                },
                .i64 => {
                    if (int_arg_idx >= abi.current.arg_gprs.len) {
                        return Error.UnsupportedOp;
                    }
                    try buf.appendSlice(allocator, inst.encStoreR64MemRBP(off, abi.current.arg_gprs[int_arg_idx]).slice());
                    int_arg_idx += 1;
                },
                .f32 => {
                    if (fp_arg_idx >= abi.current.arg_xmms.len) {
                        return Error.UnsupportedOp;
                    }
                    try buf.appendSlice(allocator, inst.encStoreXmmF32MemRBP(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                    fp_arg_idx += 1;
                },
                .f64 => {
                    if (fp_arg_idx >= abi.current.arg_xmms.len) {
                        return Error.UnsupportedOp;
                    }
                    try buf.appendSlice(allocator, inst.encStoreXmmF64MemRBP(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                    fp_arg_idx += 1;
                },
                .v128, .funcref, .externref => unreachable, // filtered above
            }
        }
    }

    // Wasm spec §4.5.3.1 — locals beyond params are initialised to
    // zero on entry. Mirror of arm64/emit.zig:263-267 (STR XZR per
    // slot). x86_64: `XOR EAX, EAX` zeros RAX (32-bit XOR zero-
    // extends to 64); then `MOV [RBP+disp], RAX` writes 8 bytes per
    // local slot. RAX is the return reg, overwritten at function-
    // end, so its temporary use here is invariant-clean.
    if (num_locals > 0) {
        try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
        var loc_idx: u32 = num_params;
        while (loc_idx < total_locals) : (loc_idx += 1) {
            const loc_disp = try localDisp(loc_idx, total_locals, uses_runtime_ptr);
            try buf.appendSlice(allocator, inst.encStoreR64MemRBP(loc_disp, .rax).slice());
        }
    }

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // For 7.7 skeleton: track a "result vreg" cursor that records
    // which vreg holds the latest pushed value. `end` reads that
    // vreg, ensures it ends up in EAX (the SysV x86_64 i32 return
    // register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;

    // Control-stack: Wasm structured-control labels (block /
    // loop). Forward fixups (br to block) land in `pending`;
    // backward jumps (br to loop) resolve immediately at the
    // `br` site since the target was captured on push.
    var labels: std.ArrayList(Label) = .empty;
    defer {
        for (labels.items) |*l| l.pending.deinit(allocator);
        labels.deinit(allocator);
    }

    // Bounds-check trap fixups: each memory op emits a
    // JAE rel32 placeholder that branches to the trap stub
    // emitted at function-final `end`. Each Fixup records the
    // Jcc instruction's byte_offset; the function-level end
    // patches them all to the trap stub address.
    var bounds_fixups: std.ArrayList(u32) = .empty;
    defer bounds_fixups.deinit(allocator);
    // §9.7 / 7.8-x86-unreachable: distinct list because JMP rel32
    // placeholders are 5 bytes (0xE9 + 4-byte disp32) while the
    // bounds-check Jcc rel32 placeholders are 6 bytes (0x0F 0x8x +
    // 4-byte disp32). Both target the same trap stub but the
    // disp formula differs by 1 byte. Patched at function-end
    // trap-stub block alongside bounds_fixups.
    var unreach_fixups: std.ArrayList(u32) = .empty;
    defer unreach_fixups.deinit(allocator);

    // Direct-call placeholders awaiting linker patch.
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    // §9.7 / 7.8-x86-mem-grow-size: dead_code tracking. After
    // `unreachable` / `return` mid-function, subsequent ops are
    // unreachable per Wasm spec §3.3 polymorphic-stack rules; the
    // validator already accepts them but this emitter would
    // attempt to lower them and trip UnsupportedOp on rare ops
    // like memory.grow inside dead code (e.g. unreachable.wast's
    // `as-memory.grow-size`). Mirror of arm64 7.5-emit-deadcode.
    var dead_code: bool = false;
    for (func.instrs.items) |ins| {
        if (dead_code) {
            switch (ins.op) {
                .@"end", .@"else" => dead_code = false,
                else => continue,
            }
        }
        switch (ins.op) {
            .@"i32.const" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const dst = try gpr.gprDefSpilled(alloc, vreg, 0);
                try buf.appendSlice(allocator, inst.encMovImm32W(dst, ins.payload).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.const" => {
                // Wasm spec §4.4.1.1 (i64.const) — push a 64-bit
                // immediate. Encoded as MOVABS r64, imm64
                // (REX.W + 0xB8+rd + 8-byte imm = 10 bytes).
                // Mirrors arm64 emitI64Const which uses 4×16-bit
                // MOVZ/MOVK chunks; x86_64's MOVABS-form is a
                // single instruction, simpler to emit.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const dst = try gpr.gprDefSpilled(alloc, vreg, 0);
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                try buf.appendSlice(allocator, inst.encMovImm64Q(dst, value).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i32.add", .@"i32.sub", .@"i32.mul",
            .@"i32.and", .@"i32.or", .@"i32.xor",
            => try op_alu_int.emitI32Binary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.eq", .@"i32.ne",
            .@"i32.lt_s", .@"i32.lt_u", .@"i32.gt_s", .@"i32.gt_u",
            .@"i32.le_s", .@"i32.le_u", .@"i32.ge_s", .@"i32.ge_u",
            => try op_alu_int.emitI32Compare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.eqz" => try op_alu_int.emitI32Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32.shl", .@"i32.shr_s", .@"i32.shr_u",
            .@"i32.rotl", .@"i32.rotr",
            => try op_alu_int.emitI32Shift(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.clz", .@"i32.ctz", .@"i32.popcnt",
            => try op_alu_int.emitI32Bitcount(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.add", .@"i64.sub", .@"i64.mul",
            .@"i64.and", .@"i64.or", .@"i64.xor",
            => try op_alu_int.emitI64Binary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.eq", .@"i64.ne",
            .@"i64.lt_s", .@"i64.lt_u", .@"i64.gt_s", .@"i64.gt_u",
            .@"i64.le_s", .@"i64.le_u", .@"i64.ge_s", .@"i64.ge_u",
            => try op_alu_int.emitI64Compare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.eqz" => try op_alu_int.emitI64Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64.shl", .@"i64.shr_s", .@"i64.shr_u",
            .@"i64.rotl", .@"i64.rotr",
            => try op_alu_int.emitI64Shift(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.clz", .@"i64.ctz", .@"i64.popcnt",
            => try op_alu_int.emitI64Bitcount(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.wrap_i64", .@"i64.extend_i32_u", .@"i64.extend_i32_s",
            => try op_alu_int.emitConvertWidth(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"call" => try op_call.emitCall(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &call_fixups, spill_base_off, func_sigs, ins.payload),
            .@"call_indirect" => try op_call.emitCallIndirect(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, module_types, ins.payload),
            .@"f32.const", .@"f64.const",
            => try op_alu_float.emitFpConst(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op, ins.payload, ins.extra),
            .@"f32.add", .@"f32.sub", .@"f32.mul", .@"f32.div",
            .@"f64.add", .@"f64.sub", .@"f64.mul", .@"f64.div",
            => try op_alu_float.emitFpBinary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.eq", .@"f32.ne", .@"f32.lt", .@"f32.gt", .@"f32.le", .@"f32.ge",
            .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge",
            => try op_alu_float.emitFpCompare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.abs", .@"f32.neg", .@"f32.sqrt",
            .@"f32.ceil", .@"f32.floor", .@"f32.trunc", .@"f32.nearest",
            .@"f64.abs", .@"f64.neg", .@"f64.sqrt",
            .@"f64.ceil", .@"f64.floor", .@"f64.trunc", .@"f64.nearest",
            => try op_alu_float.emitFpUnary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.copysign", .@"f64.copysign",
            => try op_alu_float.emitFpCopysign(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.min", .@"f32.max", .@"f64.min", .@"f64.max",
            => try op_alu_float.emitFpMinMax(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f64.promote_f32", .@"f32.demote_f64",
            .@"i32.reinterpret_f32", .@"i64.reinterpret_f64",
            .@"f32.reinterpret_i32", .@"f64.reinterpret_i64",
            .@"f32.convert_i32_s", .@"f32.convert_i64_s",
            .@"f64.convert_i32_s", .@"f64.convert_i64_s",
            .@"f32.convert_i32_u", .@"f64.convert_i32_u",
            => try op_convert.emitFpConvertSimple(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.convert_i64_u", .@"f64.convert_i64_u",
            => try op_convert.emitFpConvertI64Unsigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.trunc_sat_f32_s", .@"i32.trunc_sat_f64_s",
            .@"i64.trunc_sat_f32_s", .@"i64.trunc_sat_f64_s",
            => try op_convert.emitFpTruncSatSigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.trunc_sat_f32_u", .@"i32.trunc_sat_f64_u",
            => try op_convert.emitFpTruncSatU32(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.trunc_sat_f32_u", .@"i64.trunc_sat_f64_u",
            => try op_convert.emitFpTruncSatU64(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.trunc_f32_s", .@"i32.trunc_f64_s",
            .@"i64.trunc_f32_s", .@"i64.trunc_f64_s",
            => try op_convert.emitFpTruncTrapSigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op),
            .@"i32.trunc_f32_u", .@"i32.trunc_f64_u",
            .@"i64.trunc_f32_u", .@"i64.trunc_f64_u",
            => try op_convert.emitFpTruncTrapUnsigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op),
            .@"local.get" => try emitLocalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, func, num_params, total_locals, uses_runtime_ptr, ins.payload),
            .@"local.set" => try emitLocalSet(allocator, &buf, alloc, &pushed_vregs, spill_base_off, func, num_params, total_locals, uses_runtime_ptr, ins.payload),
            .@"local.tee" => try emitLocalTee(allocator, &buf, alloc, &pushed_vregs, spill_base_off, func, num_params, total_locals, uses_runtime_ptr, ins.payload),
            .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
            .@"i32.load16_s", .@"i32.load16_u",
            .@"i32.store", .@"i32.store8", .@"i32.store16",
            .@"i64.load", .@"i64.load8_s", .@"i64.load8_u",
            .@"i64.load16_s", .@"i64.load16_u",
            .@"i64.load32_s", .@"i64.load32_u",
            .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
            .@"f32.load", .@"f64.load",
            .@"f32.store", .@"f64.store",
            => try op_memory.emitMemOp(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op, ins.payload, func.func_idx),
            .@"global.get" => try op_globals.emitI32GlobalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"global.set" => try op_globals.emitI32GlobalSet(allocator, &buf, alloc, &pushed_vregs, spill_base_off, ins.payload),
            .@"memory.size" => {
                // Wasm spec §4.4.7 — return current memory size in
                // 64-KiB pages. mem_limit (bytes) lives at
                // [R15 + jit_abi.mem_limit_off]; pages = bytes >> 16.
                // Push fresh i32 vreg.
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) return Error.SlotOverflow;
                const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(dst_r, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
                try buf.appendSlice(allocator, inst.encShrRImm8(.q, dst_r, 16).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result_v, 0);
                try pushed_vregs.append(allocator, result_v);
            },
            .@"memory.grow" => {
                // Skeleton: emit MOV r32, -1 (grow-failed). Real
                // grow needs a runtime callout that allocates new
                // pages + updates mem_limit. Mirrors arm64's
                // skeleton (always returns -1) at this chunk; the
                // failure-only behaviour is spec-conformant for
                // any host that refuses growth. spec_assert's
                // unreachable.wast has memory.grow inside dead
                // code; handcrafted_mem doesn't grow.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?; // delta arg, unused
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) return Error.SlotOverflow;
                const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                // MOV r32, 0xFFFFFFFF  → upper 32 bits of r64 are
                // implicitly zero, but Wasm i32 reads only the low
                // 32 — value = -1 as i32.
                try buf.appendSlice(allocator, inst.encMovImm32W(dst_r, 0xFFFFFFFF).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result_v, 0);
                try pushed_vregs.append(allocator, result_v);
            },
            .@"select", .@"select_typed" => {
                // Wasm spec §4.4.4 (select / select_typed) — pop
                // c (i32), val2, val1; push val1 if c != 0 else
                // val2. x86_64 lowering (i32 only at this chunk;
                // i64 / FP variants need additional encoder
                // dispatch — surface as UnsupportedOp until
                // chunk-9 expansion):
                //   TEST c, c              ; sets ZF
                //   MOV  dst, val2         ; default
                //   CMOVNE dst, val1       ; overwrite if c != 0
                if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
                const cond_v = pushed_vregs.pop().?;
                const val2_v = pushed_vregs.pop().?;
                const val1_v = pushed_vregs.pop().?;
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) return Error.SlotOverflow;
                // D-045 chunk 13b spill staging: cond is consumed
                // first by TEST + Jcc, so its stage reg is dead
                // before val1/val2 load. Use stage 0 for cond and
                // val1, stage 1 for val2 — but cond is dead by the
                // time we load val1, so reusing stage 0 is safe.
                const cond_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, cond_v, 0);
                try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
                // After TEST sets EFLAGS, cond_r is dead — reload
                // val1 / val2 / dst through stages without reuse
                // collision.
                const val1_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, val1_v, 0);
                const val2_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, val2_v, 1);
                const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                if (dst_r != val2_r) {
                    // .q-form MOV preserves the full 64 bits in
                    // case the value happens to be an i64 select
                    // operand. The extra REX.W is harmless for i32.
                    try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, val2_r).slice());
                }
                try buf.appendSlice(allocator, inst.encCmovccRR(.q, .ne, dst_r, val1_r).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result_v, 0);
                try pushed_vregs.append(allocator, result_v);
            },
            .@"unreachable" => {
                // Wasm spec §4.4.6.1 — trap unconditionally.
                // Emit JMP rel32 placeholder; record fixup so the
                // function-end trap-stub block patches the disp32
                // to land in the trap stub (which sets trap_flag,
                // clears EAX, runs epilogue, RETs). Mirrors arm64
                // `unreachable` semantics but uses JMP rel32 (5
                // bytes) instead of B (4 bytes); the fixup list
                // is separate to carry the 5-byte disp formula.
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
                try unreach_fixups.append(allocator, fixup_at);
                dead_code = true;
            },
            .@"nop" => {
                // Wasm spec §4.4.6.2 (nop) — do nothing. No machine
                // bytes; no stack change. Mirrors arm64/emit.zig.
            },
            .@"drop" => {
                // Wasm spec §4.4.4 (drop) — pop top operand without
                // storage. No machine bytes; only the operand-stack
                // tracker advances. Mirrors arm64/emit.zig.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?;
            },
            .@"return" => {
                // Wasm spec §4.4.7 (return) — pop the function's
                // result(s) and exit. We inline the same marshal +
                // epilogue + RET sequence as the function-level
                // `end` form below; multiple physical RETs are
                // harmless on x86_64 (no jump table needed, unlike
                // ARM64 where return_fixups consolidate to a single
                // epilogue). Subsequent ops in the same body may
                // emit dead bytes that are unreachable at runtime.
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top = pushed_vregs.items[pushed_vregs.items.len - 1];
                    if (top >= alloc.slots.len) return Error.SlotOverflow;
                    switch (func.sig.results[0]) {
                        .i32, .funcref, .externref => {
                            const src = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top, 0);
                            if (src != abi.return_gpr) {
                                try buf.appendSlice(allocator, inst.encMovRR(.d, abi.return_gpr, src).slice());
                            }
                        },
                        .i64 => {
                            const src = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top, 0);
                            if (src != abi.return_gpr) {
                                try buf.appendSlice(allocator, inst.encMovRR(.q, abi.return_gpr, src).slice());
                            }
                        },
                        .f32, .f64 => {
                            const src_x = try gpr.xmmLoadSpilled(allocator, &buf, alloc, spill_base_off, top, 0);
                            if (src_x != abi.return_xmm) {
                                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(abi.return_xmm, src_x).slice());
                            }
                        },
                        .v128 => return Error.UnsupportedOp,
                    }
                }
                if (frame_bytes > 0) {
                    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
                }
                if (uses_runtime_ptr) {
                    try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
                }
                try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                try buf.appendSlice(allocator, inst.encRet().slice());
                dead_code = true;
            },
            .@"block" => try op_control.emitBlock(allocator, &labels),
            .@"loop" => try op_control.emitLoop(allocator, &buf, &labels),
            .@"br" => try op_control.emitBr(allocator, &buf, &labels, ins.payload),
            .@"br_if" => try op_control.emitBrIf(allocator, &buf, alloc, &pushed_vregs, &labels, spill_base_off, ins.payload),
            .@"br_table" => try op_control.emitBrTable(allocator, &buf, func, alloc, &pushed_vregs, &labels, spill_base_off, ins.payload, ins.extra),
            .@"if" => try op_control.emitIf(allocator, &buf, alloc, &pushed_vregs, &labels, spill_base_off, ins.extra),
            .@"else" => try op_control.emitElse(allocator, &buf, &pushed_vregs, &labels),
            .@"end" => {
                // Two distinct forms (mirrors arm64/emit.zig):
                // (A) Intra-function `end`: pops a label, patches
                //     forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns. Disambiguation: empty
                //     label stack → form (B).
                if (labels.items.len > 0) {
                    try op_control.emitEndIntra(allocator, &buf, &pushed_vregs, alloc, &labels, spill_base_off);
                    continue;
                }
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top = pushed_vregs.items[pushed_vregs.items.len - 1];
                    if (top >= alloc.slots.len) return Error.SlotOverflow;
                    switch (func.sig.results[0]) {
                        .i32, .funcref, .externref => {
                            const src = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top, 0);
                            if (src != abi.return_gpr) {
                                // MOV EAX, src — Width.d zero-extends
                                // the upper 32 bits of RAX, matching
                                // the SysV i32 / 32-bit-pointer ABI.
                                try buf.appendSlice(allocator, inst.encMovRR(.d, abi.return_gpr, src).slice());
                            }
                        },
                        .i64 => {
                            const src = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top, 0);
                            if (src != abi.return_gpr) {
                                // MOV RAX, src — Width.q preserves
                                // the full 64 bits; .d would silently
                                // truncate (D-032 root cause).
                                try buf.appendSlice(allocator, inst.encMovRR(.q, abi.return_gpr, src).slice());
                            }
                        },
                        .f32, .f64 => {
                            const src_x = try gpr.xmmLoadSpilled(allocator, &buf, alloc, spill_base_off, top, 0);
                            if (src_x != abi.return_xmm) {
                                // MOVAPS XMM0, src_xmm — copies the
                                // full 128-bit XMM. Sufficient for
                                // both f32 (low 32 used) and f64
                                // (low 64 used). Mirrors ARM64's
                                // FMOV S0/D0 marshal at
                                // arm64/emit.zig:475-503 but does
                                // not need width discrimination on
                                // x86_64.
                                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(abi.return_xmm, src_x).slice());
                            }
                        },
                        .v128 => return Error.UnsupportedOp,
                    }
                }
                // Epilogue: ADD RSP, frame ; POP R15? ; POP RBP ; RET.
                if (frame_bytes > 0) {
                    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
                }
                if (uses_runtime_ptr) {
                    try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
                }
                try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                try buf.appendSlice(allocator, inst.encRet().slice());

                // Trap stub: emitted after the regular RET when
                // the function had any bounds-check fixups. Sets
                // JitRuntime.trap_flag = 1, clears EAX (return
                // value cleared so traps don't masquerade as
                // valid returns), runs the same epilogue, RETs.
                // Each pending bounds_fixup gets its disp32
                // patched to the trap stub address.
                if (bounds_fixups.items.len > 0 or unreach_fixups.items.len > 0) {
                    const trap_byte: u32 = @intCast(buf.items.len);
                    try buf.appendSlice(allocator, inst.encStoreImm32MemDisp32(abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off, 1).slice());
                    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice()); // XOR EAX, EAX (return = 0)
                    if (frame_bytes > 0) {
                        try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
                    }
                    if (uses_runtime_ptr) {
                        try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
                    }
                    try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                    try buf.appendSlice(allocator, inst.encRet().slice());
                    for (bounds_fixups.items) |fx_byte| {
                        const disp: i32 = @as(i32, @intCast(trap_byte)) -
                            @as(i32, @intCast(fx_byte)) - 6;
                        inst.patchRel32(buf.items, fx_byte, 6, disp);
                    }
                    // unreachable fixups: 5-byte JMP rel32 (0xE9 +
                    // disp32). disp = trap_byte - (fx_byte + 5).
                    for (unreach_fixups.items) |fx_byte| {
                        const disp: i32 = @as(i32, @intCast(trap_byte)) -
                            @as(i32, @intCast(fx_byte)) - 5;
                        inst.patchRel32(buf.items, fx_byte, 5, disp);
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

/// Compute the i8 displacement for local index `idx`. Layout:
///   local 0 at [RBP - 8],  local K at [RBP - 8*(K+1)]
///       when !uses_runtime_ptr (1-PUSH prologue).
///   local 0 at [RBP - 16], local K at [RBP - 8 - 8*(K+1)]
///       when  uses_runtime_ptr (R15 occupies [RBP-8]).
/// Surfaces `UnsupportedOp` for indices the i8 disp cannot
/// reach (15 locals max either way; coincidentally same cap).
/// Returns the declared Wasm type of local index `idx`. Params
/// occupy idx 0..num_params-1; declared locals follow. Mirror
/// of arm64/emit.zig:localValType.
fn localValType(func: *const ZirFunc, num_params: u32, local_idx: u32) zir.ValType {
    if (local_idx < num_params) return func.sig.params[local_idx];
    return func.locals[local_idx - num_params];
}

fn localDisp(idx: u32, total_locals: u32, uses_runtime_ptr: bool) Error!i8 {
    if (idx >= total_locals) return Error.UnsupportedOp;
    if (idx >= 16) return Error.UnsupportedOp;
    const base_off: i32 = if (uses_runtime_ptr) -8 else 0;
    const off: i32 = base_off - @as(i32, @intCast((idx + 1) * 8));
    if (off < -128) return Error.UnsupportedOp;
    return @intCast(off);
}

/// `local.get K` — push a fresh vreg holding the value loaded
/// from [RBP + localDisp(K)].
fn emitLocalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    func: *const ZirFunc,
    num_params: u32,
    total_locals: u32,
    uses_runtime_ptr: bool,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, total_locals, uses_runtime_ptr);
    const vreg = next_vreg.*;
    next_vreg.* += 1;
    if (vreg >= alloc.slots.len) return Error.SlotOverflow;
    switch (localValType(func, num_params, idx)) {
        .i32 => {
            const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, inst.encLoadR32MemRBP(dst_r, disp).slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .i64 => {
            const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, inst.encLoadR64MemRBP(dst_r, disp).slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .f32 => {
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, inst.encLoadXmmF32MemRBP(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .f64 => {
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, inst.encLoadXmmF64MemRBP(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .v128, .funcref, .externref => return Error.UnsupportedOp,
    }
    try pushed_vregs.append(allocator, vreg);
}

/// `local.set K` — pop the top vreg and store its low 32 bits
/// into [RBP + localDisp(K)].
fn emitLocalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    num_params: u32,
    total_locals: u32,
    uses_runtime_ptr: bool,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, total_locals, uses_runtime_ptr);
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    switch (localValType(func, num_params, idx)) {
        .i32 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreR32MemRBP(disp, src_r).slice());
        },
        .i64 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreR64MemRBP(disp, src_r).slice());
        },
        .f32 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreXmmF32MemRBP(disp, src_x).slice());
        },
        .f64 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreXmmF64MemRBP(disp, src_x).slice());
        },
        .v128, .funcref, .externref => return Error.UnsupportedOp,
    }
}

/// `local.tee K` — store the top vreg's low 32 bits into
/// [RBP + localDisp(K)] WITHOUT popping.
fn emitLocalTee(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    num_params: u32,
    total_locals: u32,
    uses_runtime_ptr: bool,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, total_locals, uses_runtime_ptr);
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.items[pushed_vregs.items.len - 1];
    switch (localValType(func, num_params, idx)) {
        .i32 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreR32MemRBP(disp, src_r).slice());
        },
        .i64 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreR64MemRBP(disp, src_r).slice());
        },
        .f32 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreXmmF32MemRBP(disp, src_x).slice());
        },
        .f64 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, inst.encStoreXmmF64MemRBP(disp, src_x).slice());
        },
        .v128, .funcref, .externref => return Error.UnsupportedOp,
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "compile: empty body without liveness errors AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: empty function (no instrs) emits prologue only" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Prologue only: 55 48 89 E5 = 4 bytes (push rbp + mov rbp, rsp).
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5 }, out.bytes);
}

test "compile: (i32.const 42) end → 13 bytes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream (slot 0 = RBX after pool shrink — chunk 13b):
    //   55                       PUSH RBP
    //   48 89 E5                 MOV RBP, RSP
    //   BB 2A 00 00 00           MOV EBX, #42 (slot 0 = RBX)
    //   89 D8                    MOV EAX, EBX (return marshalling)
    //   5D                       POP RBP
    //   C3                       RET
    // Total: 1 + 3 + 5 + 2 + 1 + 1 = 13 bytes.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x2A, 0x00, 0x00, 0x00,
        0x89, 0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 0xDEADBEEF) end — little-endian imm32" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Differs from the 42 case only at the imm32 bytes. The imm32 follows the
    // 4-byte prologue + 1-byte MOV-EBX opcode (0xBB) → starts at offset 5.
    try testing.expectEqual(@as(usize, 13), out.bytes.len);
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, out.bytes[5..9]);
}

test "compile: void function with `end` only emits prologue + epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // 55 48 89 E5 5D C3 = 6 bytes (prologue + pop + ret; no return marshalling).
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5, 0x5D, 0xC3 }, out.bytes);
}

test "compile: function with 1 local + (i32.const 42) (local.set 0) (local.get 0) end" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &[_]zir.ValType{.i32});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 }, // const
        .{ .def_pc = 2, .last_use_pc = 3 }, // local.get result
    } };
    const slots = [_]u8{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream (slot 0 = RBX, slot 1 = R12 after pool shrink — chunk 13b):
    //   55 48 89 E5                    PUSH RBP ; MOV RBP, RSP
    //   48 83 EC 10                    SUB RSP, 16            (1 local → 16 aligned)
    //   BB 2A 00 00 00                 MOV EBX, #42           (const, slot 0 = RBX)
    //   89 5D F8                       MOV [RBP-8], EBX       (local.set 0)
    //   44 8B 65 F8                    MOV R12D, [RBP-8]      (local.get 0; slot 1 = R12)
    //   31 C0                          XOR EAX, EAX        (zero-init §4.5.3.1)
    //   48 89 45 F8                    MOV [RBP-8], RAX    (zero local 0)
    //   BB 2A 00 00 00                 MOV EBX, 42
    //   89 5D F8                       MOV [RBP-8], EBX
    //   44 8B 65 F8                    MOV R12D, [RBP-8]
    //   44 89 E0                       MOV EAX, R12D
    //   48 83 C4 10                    ADD RSP, 16
    //   5D                             POP RBP
    //   C3                             RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x48, 0x83, 0xEC, 0x10,
        0x31, 0xC0,
        0x48, 0x89, 0x45, 0xF8,
        0xBB, 0x2A, 0x00, 0x00, 0x00,
        0x89, 0x5D, 0xF8,
        0x44, 0x8B, 0x65, 0xF8,
        0x44, 0x89, 0xE0,
        0x48, 0x83, 0xC4, 0x10,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: local.tee preserves stack — uses top vreg without popping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &[_]zir.ValType{.i32});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0}; // R10D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // local.tee writes [RBP-8] but doesn't pop, so the top vreg
    // (slot 0 = RBX after chunk 13b pool shrink) is still on the stack
    // for the `end` to marshal into EAX.
    // Expected: prologue(4) + SUB(4) + zero-init(6) + MOV EBX #7 (5)
    // + MOV [RBP-8] EBX (3) + MOV EAX EBX (2) + ADD RSP + POP RBP + RET.
    // Spot-check: STORE [RBP-8] EBX = 89 5D F8 at offset 19..22,
    // followed by MOV EAX, EBX = 89 D8 at 22..24.
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x5D, 0xF8 }, out.bytes[19..22]);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0xD8 }, out.bytes[22..24]);
}

test "compile: (block (br 0) end) end — forward br with end-patch" {
    // Empty block with br to its own end. Then function-end.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // intra: closes block
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // function-level
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue (no SUB RSP — no locals)
    //   E9 00 00 00 00                 JMP rel32, patched to disp=0 (target = next byte)
    //   5D                             POP RBP (function-level end)
    //   C3                             RET
    // The JMP's disp is 0 because the patch site is at offset 4
    // (after prologue) + insn_size 5 → next instruction at offset 9,
    // which IS the block's end target. Disp = 9 - 9 = 0.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xE9, 0x00, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (loop (br 0) end) end — backward br with concrete disp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // intra: closes loop (no patch)
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // loop captures byte_offset = 4 (post-prologue). br at offset 4
    // emits JMP with disp = 4 - 4 - 5 = -5. So bytes:
    //   55 48 89 E5                    prologue
    //   E9 FB FF FF FF                 JMP -5 (back to loop entry — infinite loop)
    //   5D C3                          POP RBP ; RET (unreachable but emitted)
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xE9, 0xFB, 0xFF, 0xFF, 0xFF,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 1) (if) (i32.const 7) (end) end — single-arm if; JE patched" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected layout (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink):
    //   55 48 89 E5                    prologue              [0..4]
    //   BB 01 00 00 00                 MOV EBX, #1           [4..9]
    //   85 DB                          TEST EBX, EBX         [9..11]
    //   0F 84 06 00 00 00              JE +6 (skip then-body) [11..17]
    //   41 BC 07 00 00 00              MOV R12D, #7          [17..23]
    //   5D                             POP RBP               [23]
    //   C3                             RET                   [24]
    // JE disp = 23 - 17 = 6 (skip from after JE to past then-body's
    // i32.const 7). Then-body is 6 bytes (MOV R12D #7).
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x01, 0x00, 0x00, 0x00,
        0x85, 0xDB,
        0x0F, 0x84, 0x06, 0x00, 0x00, 0x00,
        0x41, 0xBC, 0x07, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (block (i32.const 0) (br_if 0) end) end — Jcc forward fixup" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_if", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected (slot 0 = RBX after chunk 13b pool shrink):
    //   55 48 89 E5                    prologue              [0..4]
    //   BB 00 00 00 00                 MOV EBX, #0           [4..9]
    //   85 DB                          TEST EBX, EBX         [9..11]
    //   0F 85 00 00 00 00              JNE +0 (block-end)    [11..17] disp = 17-17 = 0
    //   5D C3                          POP RBP ; RET         [17..19]
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x00, 0x00, 0x00, 0x00,
        0x85, 0xDB,
        0x0F, 0x85, 0x00, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (loop (i32.const 0) (br_if 0) end) end — Jcc backward concrete disp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_if", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // loop entry at offset 4 (post-prologue). After chunk 13b pool shrink,
    // br_if Jcc at offset 11; disp = 4 - 11 - 6 = -13 = 0xFFFFFFF3.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x00, 0x00, 0x00, 0x00,
        0x85, 0xDB,
        0x0F, 0x85, 0xF3, 0xFF, 0xFF, 0xFF,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: br_table — single case + default both → block end" {
    // (block (i32.const 0) (br_table 1 0 0) end) end
    // count=1, case 0 → block (depth 0), default → block (depth 0).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.branch_targets.append(testing.allocator, 0); // case 0 depth
    try f.branch_targets.append(testing.allocator, 0); // default depth
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_table", .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream (slot 0 = RBX after chunk 13b pool shrink):
    //   55 48 89 E5                    prologue              [0..4]
    //   BB 00 00 00 00                 MOV EBX, #0           [4..9]
    //   83 FB 00                       CMP EBX, 0            [9..12]
    //   75 05                          JNE +5 (skip JMP)     [12..14]
    //   E9 05 00 00 00                 JMP case-0 → block end (forward fixup; patched to disp=5) [14..19]
    //   E9 00 00 00 00                 JMP default → block end (forward fixup; patched to disp=0) [19..24]
    //   5D C3                          POP RBP ; RET         [24..26]
    // Block end target = 24. case JMP at 14 → disp=24-14-5=5. default JMP at 19 → disp=24-19-5=0.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x00, 0x00, 0x00, 0x00,
        0x83, 0xFB, 0x00,
        0x75, 0x05,
        0xE9, 0x05, 0x00, 0x00, 0x00,
        0xE9, 0x00, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: br_table count > 127 → UnsupportedOp (i8 cap)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < 129) : (i += 1) try f.branch_targets.append(testing.allocator, 0);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_table", .payload = 128, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: (i32.const 0) i32.load offset=0 end — ADR-0026 prologue + bounds check + load" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 }, // const → idx
        .{ .def_pc = 1, .last_use_pc = 2 }, // load result
    } };
    const slots = [_]u8{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // ADR-0026 prologue (uses_runtime_ptr=true):
    //   55                          PUSH RBP                          [0]
    //   41 57                       PUSH R15                          [1..3]
    //   48 89 E5                    MOV RBP, RSP                      [3..6]
    //   49 89 FF                    MOV R15, RDI                      [6..9]
    //   48 83 EC 08                 SUB RSP, 8 (locals=0 → frame=8)   [9..13]
    // Body (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink):
    //   BB 00 00 00 00              MOV EBX, #0   (idx vreg 0)        [13..18]
    //   49 8B 87 00 00 00 00        MOV RAX, [R15 + 0] (vm_base)      [18..25]
    //   89 DA                       MOV EDX, EBX (zero-extend idx)    [25..27]
    //   48 8D 4A 04                 LEA RCX, [RDX + 4] (ea + size=4)  [27..31]
    //   49 3B 8F 08 00 00 00        CMP RCX, [R15 + 8]                [31..38]
    //   0F 87 ?? ?? ?? ??           JA trap_stub (placeholder)        [38..44]
    //   44 8B 24 10                 MOV R12D, [RAX + RDX]             [44..48]
    //   44 89 E0                    MOV EAX, R12D (return marshalling)[48..51]
    // Epilogue:
    //   48 83 C4 08                 ADD RSP, 8                        [51..55]
    //   41 5F                       POP R15                           [55..57]
    //   5D                          POP RBP                           [57]
    //   C3                          RET                               [58]
    // Trap stub:
    //   41 C7 87 28 00 00 00 01 00 00 00   MOV [R15+40], 1            [59..70]
    //   31 C0                              XOR EAX, EAX               [70..72]
    //   48 83 C4 08                        ADD RSP, 8                 [72..76]
    //   41 5F                              POP R15                    [76..78]
    //   5D                                 POP RBP                    [78]
    //   C3                                 RET                        [79]
    //
    // JA patch: trap_byte = 59. fixup_byte = 38, insn_size = 6.
    //   disp = 59 - 38 - 6 = 15 = 0x0F.
    //
    // Total length: 80 bytes.
    try testing.expectEqual(@as(usize, 80), out.bytes.len);
    // Spot-check the prologue (verifies ADR-0026 structure).
    // The MOV R15, <entry_arg0> byte differs by Cc; derive the
    // expected sequence dynamically so this works on both SysV
    // and Win64 builds.
    const exp_push_rbp = inst.encPushR(.rbp);
    const exp_push_r15 = inst.encPushR(.r15);
    const exp_mov_rbp_rsp = inst.encMovRR(.q, .rbp, .rsp);
    const exp_mov_r15_arg0 = inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, abi.current.entry_arg0_gpr);
    const exp_sub_rsp_8 = inst.encSubRSpImm8(8);
    var exp_prologue: [13]u8 = undefined;
    var off: usize = 0;
    @memcpy(exp_prologue[off .. off + exp_push_rbp.len], exp_push_rbp.slice()); off += exp_push_rbp.len;
    @memcpy(exp_prologue[off .. off + exp_push_r15.len], exp_push_r15.slice()); off += exp_push_r15.len;
    @memcpy(exp_prologue[off .. off + exp_mov_rbp_rsp.len], exp_mov_rbp_rsp.slice()); off += exp_mov_rbp_rsp.len;
    @memcpy(exp_prologue[off .. off + exp_mov_r15_arg0.len], exp_mov_r15_arg0.slice()); off += exp_mov_r15_arg0.len;
    @memcpy(exp_prologue[off .. off + exp_sub_rsp_8.len], exp_sub_rsp_8.slice()); off += exp_sub_rsp_8.len;
    try testing.expectEqual(@as(usize, 13), off);
    try testing.expectEqualSlices(u8, &exp_prologue, out.bytes[0..13]);
    // Spot-check the JA placeholder is patched (disp = 15 = 0x0F): JA = 0x0F 0x87 at byte 38.
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x87, 0x0F, 0x00, 0x00, 0x00 }, out.bytes[38..44]);
    // Spot-check trap stub starts at 59 with the trap_flag store:
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xC7, 0x87, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, out.bytes[59..70]);
}

test "compile: i32.load with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: (i32.const 0)(i32.const 99) i32.store offset=0 — store path" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });   // idx
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });  // value
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 }, // idx (R10D)
        .{ .def_pc = 1, .last_use_pc = 2 }, // value (R11D)
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Prologue: 13 bytes (PUSH RBP / PUSH R15 / MOV RBP,RSP / MOV R15,RDI / SUB RSP,8)
    // Body (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink):
    //   BB 00 00 00 00                 MOV EBX, 0   (idx)             5 bytes
    //   41 BC 63 00 00 00              MOV R12D, 99 (value)           6
    //   49 8B 87 00 00 00 00           MOV RAX, [R15 + 0]             7
    //   89 DA                          MOV EDX, EBX                   2
    //   48 8D 4A 04                    LEA RCX, [RDX + 4]             4
    //   49 3B 8F 08 00 00 00           CMP RCX, [R15 + 8]             7
    //   0F 87 ?? ?? ?? ??              JA trap_stub (placeholder)     6
    //   44 89 24 10                    MOV [RAX + RDX], R12D          4
    //   (no return marshalling — sig.results.len == 0)
    // Epilogue: ADD RSP,8 / POP R15 / POP RBP / RET                  8
    // Trap stub: 21 bytes
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x24, 0x10 }, out.bytes[13 + 5 + 6 + 7 + 2 + 4 + 7 + 6 ..][0..4]);
    // Verify the JA was patched (disp != 0); JA = 0x0F 0x87
    const ja_at = 13 + 5 + 6 + 7 + 2 + 4 + 7;
    try testing.expect(out.bytes[ja_at] == 0x0F and out.bytes[ja_at + 1] == 0x87);
    const disp = std.mem.readInt(i32, out.bytes[ja_at + 2 ..][0..4], .little);
    try testing.expect(disp > 0); // forward to trap stub
}

test "compile: (i32.const 0) i32.load8_u → MOVZX r8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load8_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Find MOVZX r32, byte ptr [RAX + RDX]: REX.R + 0F B6 24 10
    // dst is R12D (slot 1 after chunk 13b pool shrink) → REX = 0x44, then 0F B6 24 10
    const expected = [_]u8{ 0x44, 0x0F, 0xB6, 0x24, 0x10 };
    // The load is the last body insn before return marshalling (MOV EAX, R11D).
    // Search; not asserting the exact offset to avoid coupling to prologue width.
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 0) i32.load16_s → MOVSX r16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load16_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // MOVSX r32, word ptr [RAX + RDX] for R12D (slot 1 after chunk 13b pool shrink):
    // REX.R + 0F BF 24 10
    const expected = [_]u8{ 0x44, 0x0F, 0xBF, 0x24, 0x10 };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 0)(i32.const 7) i32.store8 → MOV r8 store" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store8" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // MOV [RAX + RDX], R12B (8-bit; slot 1 = R12 after chunk 13b pool shrink):
    // REX.R for R12 → 44 88 24 10
    const expected = [_]u8{ 0x44, 0x88, 0x24, 0x10 };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.store with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store" }); // needs 2 vregs, has 1
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: global.get 0 — emits ADR-0027 reload-from-runtime-ptr (i32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // R10D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Body should contain the 2-instruction global.get sequence:
    //   MOV RAX, [R15 + globals_base_off=48] →  49 8B 87 30 00 00 00
    //   MOV EBX, [RAX + 0]                   →  8B 98 00 00 00 00
    // (slot 0 = RBX after chunk 13b pool shrink — no REX prefix needed.)
    const expected = [_]u8{
        0x49, 0x8B, 0x87, 0x30, 0x00, 0x00, 0x00, // MOV RAX, [R15 + 48]
        0x8B, 0x98, 0x00, 0x00, 0x00, 0x00, // MOV EBX, [RAX + 0]
    };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 42) global.set 1 — emits ADR-0027 reload + store (i32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Body should contain the global.set sequence:
    //   MOV RAX, [R15 + 48]                  →  49 8B 87 30 00 00 00
    //   MOV [RAX + 8], EBX  (idx=1, byte_off=8) →  89 98 08 00 00 00
    // (slot 0 = RBX after chunk 13b pool shrink — no REX prefix needed.)
    const expected = [_]u8{
        0x49, 0x8B, 0x87, 0x30, 0x00, 0x00, 0x00,
        0x89, 0x98, 0x08, 0x00, 0x00, 0x00,
    };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: global.set with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty, &.{}, &.{}));
}

test "compile: br with depth out of range → UnsupportedOp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 }); // no enclosing block/loop
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: function with > 15 locals → UnsupportedOp (i8 disp range)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const sixteen_locals = [_]zir.ValType{.i32} ** 16;
    var f = ZirFunc.init(0, sig, &sixteen_locals);
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: function with v128 param → UnsupportedOp (v128 not yet supported)" {
    // Chunks 6+7 added i32/i64/f32/f64 params. v128/funcref/
    // externref remain unsupported until SIMD / refs phases.
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{.v128}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: i32 param + local.get + end — params marshal MOV [rbp-8], esi" {
    // §9.7 / 7.8-x86-params smoke test. (param i32) → i32 returns
    // the param value via local.get 0. SysV: arg_gprs[1] = RSI.
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{.i32}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // The marshalled MOV [rbp-8], <argreg> appears between the
    // SUB RSP and the body's local.get. SysV's user int arg 0 is
    // RSI; Win64's user int arg 0 is RDX. Either way it goes to
    // [rbp-8] (no uses_runtime_ptr; first local at offset -8).
    const expected = inst.encStoreR32MemRBP(-8, abi.current.arg_gprs[1]);
    // Search the prologue range for the marshal byte sequence.
    const prologue_end: usize = 12; // PUSH RBP + MOV RBP,RSP + SUB RSP,16
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= prologue_end + expected.len) : (i += 1) {
        if (i + expected.len > out.bytes.len) break;
        if (std.mem.eql(u8, expected.slice(), out.bytes[i .. i + expected.len])) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 7) (i32.const 5) i32.add end — verifies ADD is emitted" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 }; // RBX, R12D, R13D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55                       PUSH RBP
    //   48 89 E5                 MOV RBP, RSP
    //   BB 07 00 00 00           MOV EBX, #7   (vreg 0 → slot 0 → RBX)
    //   41 BC 05 00 00 00        MOV R12D, #5  (vreg 1 → slot 1 → R12)
    //   41 89 DD                 MOV R13D, EBX (vreg 2 → slot 2 → R13, lhs lift)
    //   45 01 E5                 ADD R13D, R12D (rhs add)
    //   44 89 E8                 MOV EAX, R13D (return marshalling)
    //   5D                       POP RBP
    //   C3                       RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x07, 0x00, 0x00, 0x00,
        0x41, 0xBC, 0x05, 0x00, 0x00, 0x00,
        0x41, 0x89, 0xDD,
        0x45, 0x01, 0xE5,
        0x44, 0x89, 0xE8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 8) (i32.const 3) i32.sub end — SUB opcode 29" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 3 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.sub" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Spot-check (slot 2 = R13, slot 1 = R12 after chunk 13b pool shrink):
    // SUB R13D, R12D = 45 29 E5 lives at offset 18..21.
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x29, 0xE5 }, out.bytes[18..21]);
}

test "compile: (i32.const 6) (i32.const 7) i32.mul end — IMUL 0F AF" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 6 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.mul" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // IMUL r9, r/m9 has flipped REX semantics (slot 2 = R13, slot 1 = R12 after
    // chunk 13b pool shrink). dst=R13D (R=1), src=R12D (B=1) → REX = 0x45.
    // ModR/M: mod=11, reg=101 (r13), rm=100 (r12) → 11 101 100 = EC.
    // So 45 0F AF EC at offset 18..22.
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0xAF, 0xEC }, out.bytes[18..22]);
}

test "compile: (i32.const 7) (i32.const 5) i32.eq end — CMP+SETE+MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eq" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 }; // RBX, R12D, R13D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   BB 07 00 00 00                  MOV EBX, #7
    //   41 BC 05 00 00 00               MOV R12D, #5
    //   44 39 E3                        CMP EBX, R12D
    //   41 0F 94 C5                     SETE R13B
    //   45 0F B6 ED                     MOVZX R13D, R13B
    //   44 89 E8                        MOV EAX, R13D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x07, 0x00, 0x00, 0x00,
        0x41, 0xBC, 0x05, 0x00, 0x00, 0x00,
        0x44, 0x39, 0xE3,
        0x41, 0x0F, 0x94, 0xC5,
        0x45, 0x0F, 0xB6, 0xED,
        0x44, 0x89, 0xE8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.lt_s vs i32.lt_u — different cc codes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{ .{ .op = .@"i32.lt_s", .cc = @as(u8, 0x9C) }, .{ .op = .@"i32.lt_u", .cc = @as(u8, 0x92) } }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 2 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 2 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // SETcc opcode byte (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink).
        // Layout: [prologue 4][movimm-EBX 5][movimm-R12D 6][cmp 3] = 18,
        // then SETcc REX(41) at 18, 0x0F at 19, opcode at 20.
        try testing.expectEqual(case.cc, out.bytes[20]);
    }
}

test "compile: (i32.const 0) i32.eqz end — TEST+SETE+MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 }; // RBX, R12D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   BB 00 00 00 00                  MOV EBX, #0
    //   85 DB                           TEST EBX, EBX
    //   41 0F 94 C4                     SETE R12B   (REX.B for r12)
    //   45 0F B6 E4                     MOVZX R12D, R12B
    //   44 89 E0                        MOV EAX, R12D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x00, 0x00, 0x00, 0x00,
        0x85, 0xDB,
        0x41, 0x0F, 0x94, 0xC4,
        0x45, 0x0F, 0xB6, 0xE4,
        0x44, 0x89, 0xE0,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 1) (i32.const 4) i32.shl end — MOV CL + MOV dst + SHL CL" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.shl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 }; // RBX, R12D, R13D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   BB 01 00 00 00                  MOV EBX, #1     (vreg 0 = lhs)
    //   41 BC 04 00 00 00               MOV R12D, #4    (vreg 1 = rhs)
    //   44 89 E1                        MOV ECX, R12D   (rhs → CL count)
    //   41 89 DD                        MOV R13D, EBX   (lhs → dst)
    //   41 D3 E5                        SHL R13D, CL
    //   44 89 E8                        MOV EAX, R13D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x01, 0x00, 0x00, 0x00,
        0x41, 0xBC, 0x04, 0x00, 0x00, 0x00,
        0x44, 0x89, 0xE1,
        0x41, 0x89, 0xDD,
        0x41, 0xD3, 0xE5,
        0x44, 0x89, 0xE8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.shr_s vs i32.shr_u — kind byte differs (sar 41 D3 fd vs shr 41 D3 ed)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{
        .{ .op = .@"i32.shr_s", .modrm = @as(u8, 0xFD) },
        .{ .op = .@"i32.shr_u", .modrm = @as(u8, 0xED) },
    }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 2 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 2 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // Layout (slot 0=RBX, slot 1=R12, slot 2=R13 after chunk 13b pool shrink):
        // 4 prologue + 5 mov-EBX + 6 mov-R12D + 3 mov-ECX + 3 mov-R13D = 21,
        // then REX 0x41 at 21, D3 at 22, ModR/M at 23.
        try testing.expectEqual(@as(u8, 0xD3), out.bytes[22]);
        try testing.expectEqual(case.modrm, out.bytes[23]);
    }
}

test "compile: (i32.const 8) i32.clz end — LZCNT" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 }; // RBX, R12D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue
    //   BB 08 00 00 00                 MOV EBX, #8
    //   F3 44 0F BD E3                 LZCNT R12D, EBX (dst=R12 reg, src=EBX r/m)
    //   44 89 E0                       MOV EAX, R12D
    //   5D C3                          POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xBB, 0x08, 0x00, 0x00, 0x00,
        0xF3, 0x44, 0x0F, 0xBD, 0xE3,
        0x44, 0x89, 0xE0,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.clz vs i32.ctz vs i32.popcnt — opcode byte differs" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{
        .{ .op = .@"i32.clz",    .opcode = @as(u8, 0xBD) },
        .{ .op = .@"i32.ctz",    .opcode = @as(u8, 0xBC) },
        .{ .op = .@"i32.popcnt", .opcode = @as(u8, 0xB8) },
    }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u8{ 0, 1 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // Layout (slot 0 = RBX after chunk 13b pool shrink):
        // 4 prologue + 5 mov-EBX-imm32 = 9. Then F3 at 9, REX at 10 (0x44),
        // 0x0F at 11, opcode at 12.
        try testing.expectEqual(@as(u8, 0xF3), out.bytes[9]);
        try testing.expectEqual(@as(u8, 0x0F), out.bytes[11]);
        try testing.expectEqual(case.opcode, out.bytes[12]);
    }
}

test "compile: i32.eqz with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" }); // no operand on stack
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: i32.wrap_i64 emits MOV r32_dst, r32_src (self-MOV zero-extends)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // x86_64 doesn't yet have i64.const; use i32.const as the i64-typed
    // source stand-in (emit pass doesn't validate types).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xCAFE });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // Both vregs in slot 0 → RBX (after chunk 13b pool shrink). wrap-op
    // materialises as self-MOV (still issued: the 32-bit write zeroes the
    // upper half).
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout: 4 prologue + 5 mov-EBX-imm32 = 9. Then MOV EBX, EBX = 2 bytes.
    const expected = inst.encMovRR(.d, .rbx, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[9 .. 9 + expected.len]);
}

test "compile: i64.extend_i32_u emits MOV r32_dst, r32_src" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
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
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    // 4 prologue + 5 mov-EBX-imm32 = 9. Then MOV EBX, EBX = 2 bytes.
    const expected = inst.encMovRR(.d, .rbx, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[9 .. 9 + expected.len]);
}

test "compile: i64.extend_i32_s emits MOVSXD r64_dst, r32_src" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Sign-bit set source — extend_i32_s should produce a negative i64.
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
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    // 4 prologue + 5 mov-EBX-imm32 = 9. Then MOVSXD RBX, EBX = 3 bytes.
    const expected = inst.encMovsxdR64R32(.rbx, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[9 .. 9 + expected.len]);
}

test "compile: call N — 0 args, void return — emits MOV RDI,R15 + CALL + fixup" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    const slots = [_]u8{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{});
    defer deinit(testing.allocator, out);

    // Prologue (uses_runtime_ptr=true since `call` triggers prescan):
    //   PUSH RBP        55              (1 byte)
    //   PUSH R15        41 57           (2 bytes) → 3
    //   MOV RBP, RSP    48 89 e5        (3 bytes) → 6
    //   MOV R15, RDI    49 89 fd        (3 bytes) → 9
    //   SUB RSP, 8      48 83 ec 08     (4 bytes) → 13   (frame_bytes=8 for N=0 + uses_rtp)
    // Body starts at byte 13.
    //   MOV RDI, R15    4c 89 ff        (3 bytes) → 16
    //   CALL rel32      e8 00 00 00 00  (5 bytes) → 21
    // Cc-pivot: assert MOV <entry_arg0>, R15 (RDI on SysV, RCX
    // on Win64). encMovRR length is 3 in both cases (only modrm
    // byte differs); the call-fixup byte offset stays at 16.
    const expected_mov = inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.current.runtime_ptr_save_gpr);
    try testing.expectEqualSlices(u8, expected_mov.slice(), out.bytes[13 .. 13 + expected_mov.len]);
    // Win64 shadow space: SUB RSP, 32 (4-byte encoding) must
    // precede the CALL; ADD RSP, 32 (4-byte encoding) follows.
    // SysV: no SUB/ADD; the byte at offset 16 is the CALL opcode.
    const shadow_enc_len: u32 = if (abi.current.shadow_space_bytes > 0) 4 else 0;
    if (shadow_enc_len > 0) {
        const expected_sub = inst.encSubRSpImm8(@intCast(abi.current.shadow_space_bytes));
        try testing.expectEqualSlices(u8, expected_sub.slice(), out.bytes[16 .. 16 + expected_sub.len]);
        const post_call: u32 = 16 + shadow_enc_len + 5;
        const expected_add = inst.encAddRSpImm8(@intCast(abi.current.shadow_space_bytes));
        try testing.expectEqualSlices(u8, expected_add.slice(), out.bytes[post_call .. post_call + expected_add.len]);
    }
    // CALL byte offset = post-prologue (13) + MOV <arg0>, R15
    // (3) + shadow encoding length. SysV: 16; Win64: 20.
    const call_off: u32 = 16 + shadow_enc_len;
    const expected_call = inst.encCallRel32(0);
    try testing.expectEqualSlices(u8, expected_call.slice(), out.bytes[call_off .. call_off + expected_call.len]);

    try testing.expectEqual(@as(usize, 1), out.call_fixups.len);
    try testing.expectEqual(call_off, out.call_fixups[0].byte_offset);
    try testing.expectEqual(@as(u32, 1), out.call_fixups[0].target_func_idx);
}

test "compile: call N — 0 args, i32 return — captures EAX into result vreg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u8{0}; // result vreg → RBX (after chunk 13b pool shrink)
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{});
    defer deinit(testing.allocator, out);

    // Body layout (post-prologue at 13). Capture-result offset
    // shifts by 2× shadow encoding (SUB before + ADD after the
    // 5-byte CALL). SysV: 21; Win64: 29.
    const shadow_enc_len: u32 = if (abi.current.shadow_space_bytes > 0) 4 else 0;
    const capture_off: u32 = 13 + 3 + shadow_enc_len + 5 + shadow_enc_len;
    const expected_capture = inst.encMovRR(.d, .rbx, .rax);
    try testing.expectEqualSlices(u8, expected_capture.slice(), out.bytes[capture_off .. capture_off + expected_capture.len]);
}

test "compile: call N — 1 i32 arg — marshals top-of-stack into arg_gprs[1] (RSI on SysV, RDX on Win64)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{.i32}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u8{0}; // arg vreg → RBX (after chunk 13b pool shrink)
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{});
    defer deinit(testing.allocator, out);

    // Body layout (post-prologue at 13). Cc-pivot derives the
    // marshalling target from `abi.current.arg_gprs[1]`.
    //   MOV EBX, 42                      (5 bytes) → 18
    //   MOV <arg1>, EBX                  (2-3 bytes; varies by arch) → marshal
    //   MOV <arg0>, R15                  (3 bytes) → runtime_ptr restore
    //   CALL rel32                       (5 bytes)
    const expected_marshal = inst.encMovRR(.d, abi.current.arg_gprs[1], .rbx);
    try testing.expectEqualSlices(u8, expected_marshal.slice(), out.bytes[18 .. 18 + expected_marshal.len]);
}

test "compile: call_indirect — bounds + sig (JAE+JNE → trap stub) + CALL RAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const module_types = [_]zir.FuncType{callee_sig};

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u8{0}; // idx vreg → RBX (after chunk 13b pool shrink)
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &module_types);
    defer deinit(testing.allocator, out);

    // Body starts at byte 13 (uses_runtime_ptr=true prologue).
    // Slot 0 = RBX → no REX.R/B for the idx; encodings shrink vs the
    // pre-13b R10 layout.
    //   [13..18]  MOV EBX, 5              (i32.const, 5 bytes)
    //   [18..25]  MOV EAX, [R15 + 24]     (load table_size, 7 bytes)
    //   [25..27]  CMP EBX, EAX            (bounds compare, 2 bytes)
    //   [27..33]  JAE rel32 placeholder   (bounds fixup, 6 bytes)
    //   [33..40]  MOV RAX, [R15 + 32]     (load typeidx_base, 7 bytes)
    //   [40..43]  MOV EAX, [RAX + RBX*4]  (load expected typeidx, 3 bytes)
    //   [43..49]  CMP EAX, 0              (sig compare to type_idx=0, 6 bytes)
    //   [49..55]  JNE rel32 placeholder   (sig fixup, 6 bytes)
    //   [55..62]  MOV RAX, [R15 + 16]     (load funcptr_base, 7 bytes)
    //   [62..66]  MOV RAX, [RAX + RBX*8]  (load funcptr, 4 bytes)
    //   [66..69]  MOV RDI, R15            (restore runtime_ptr, 3 bytes)
    //   [69..71]  CALL RAX                (indirect)
    const expected_table_size_load = inst.encMovR32FromMemDisp32(.rax, .r15, 24);
    try testing.expectEqualSlices(u8, expected_table_size_load.slice(), out.bytes[18 .. 18 + expected_table_size_load.len]);
    // JAE/JNE rel32 disp32 is patched at function-tail to point at the
    // trap stub; assert only the opcode bytes (0F 83 / 0F 85).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[27]);
    try testing.expectEqual(@as(u8, 0x83), out.bytes[28]);
    const expected_typeidx_load = inst.encMovR32FromBaseIdxLsl2(.rax, .rax, .rbx);
    try testing.expectEqualSlices(u8, expected_typeidx_load.slice(), out.bytes[40 .. 40 + expected_typeidx_load.len]);
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[49]);
    try testing.expectEqual(@as(u8, 0x85), out.bytes[50]);
    const expected_funcptr_load = inst.encMovR64FromBaseIdxLsl3(.rax, .rax, .rbx);
    try testing.expectEqualSlices(u8, expected_funcptr_load.slice(), out.bytes[62 .. 62 + expected_funcptr_load.len]);
    // Cc-pivot: CALL RAX shifts by `shadow_space_bytes` encoding
    // length (Win64 inserts SUB RSP, 32 before the indirect CALL).
    const shadow_enc_len: u32 = if (abi.current.shadow_space_bytes > 0) 4 else 0;
    const call_off: u32 = 69 + shadow_enc_len;
    const expected_call = inst.encCallReg(.rax);
    try testing.expectEqualSlices(u8, expected_call.slice(), out.bytes[call_off .. call_off + expected_call.len]);
}

test "compile: f32.const — MOV EAX,bits + MOVD XMM8,EAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bit pattern = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // FP slot 0 → XMM8
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Prologue (uses_runtime_ptr=false; no calls/memory) = 4 bytes.
    //   PUSH RBP        55              (1)
    //   MOV RBP, RSP    48 89 e5        (3) → 4
    // Body:
    //   MOV EAX, bits   b8 + 4 imm      (5) → 9
    //   MOVD XMM8,EAX   66 44 0f 6e c0  (5) → 14
    const expected_imm = inst.encMovImm32W(.rax, 0x3F800000);
    try testing.expectEqualSlices(u8, expected_imm.slice(), out.bytes[4 .. 4 + expected_imm.len]);
    const expected_movd = inst.encMovdXmmFromR32(.xmm8, .rax);
    try testing.expectEqualSlices(u8, expected_movd.slice(), out.bytes[9 .. 9 + expected_movd.len]);
}

test "compile: f64.const — MOVABS RAX,bits + MOVQ XMM8,RAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0 bit pattern = 0x3FF0000000000000. Split into payload + extra.
    const bits: u64 = 0x3FF0000000000000;
    try f.instrs.append(testing.allocator, .{
        .op = .@"f64.const",
        .payload = @truncate(bits),
        .extra = @truncate(bits >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body layout (post-prologue at 4):
    //   MOVABS RAX,bits 48 b8 + 8 imm   (10) → 14
    //   MOVQ XMM8,RAX   66 4c 0f 6e c0  (5)  → 19
    const expected_imm = inst.encMovImm64Q(.rax, bits);
    try testing.expectEqualSlices(u8, expected_imm.slice(), out.bytes[4 .. 4 + expected_imm.len]);
    const expected_movq = inst.encMovqXmmFromR64(.xmm8, .rax);
    try testing.expectEqualSlices(u8, expected_movq.slice(), out.bytes[14 .. 14 + expected_movq.len]);
}

test "compile: f32.add — MOVAPS XMM10,XMM8 + ADDSS XMM10,XMM9" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // FP slots 0,1,2 → XMM8, XMM9, XMM10.
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body layout (4-byte prologue):
    //   [4..14]  f32.const 0x3F800000 (10 bytes: MOV EAX + MOVD XMM8)
    //   [14..24] f32.const 0x40000000 (10 bytes: MOV EAX + MOVD XMM9)
    //   [24..28] MOVAPS XMM10, XMM8   (4 bytes)
    //   [28..33] ADDSS XMM10, XMM9    (5 bytes)
    const expected_movaps = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[24 .. 24 + expected_movaps.len]);
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[28 .. 28 + expected_addss.len]);
}

test "compile: f64.mul — MOVAPS XMM10,XMM8 + MULSD XMM10,XMM9" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0 = 0x3FF0000000000000 split low/high.
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    // 2.0 = 0x4000000000000000 split low/high.
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.mul" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body layout (4-byte prologue):
    //   [4..19]  f64.const 1.0 (15 bytes: MOVABS RAX + MOVQ XMM8,RAX)
    //   [19..34] f64.const 2.0 (15 bytes)
    //   [34..38] MOVAPS XMM10, XMM8 (4 bytes)
    //   [38..43] MULSD XMM10, XMM9  (5 bytes)
    const expected_movaps = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[34 .. 34 + expected_movaps.len]);
    const expected_mulsd = inst.encSseScalarBinary(.f64, 0x59, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_mulsd.slice(), out.bytes[38 .. 38 + expected_mulsd.len]);
}

test "compile: f64.promote_f32 — CVTSS2SD XMM9, XMM8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.promote_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]: CVTSS2SD XMM9, XMM8 at [14..19].
    const expected = inst.encSseScalarBinary(.f32, 0x5A, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[14 .. 14 + expected.len]);
}

test "compile: i32.reinterpret_f32 — MOVD R10D, XMM8 (XMM→GPR bit-cast)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.reinterpret_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // FP slot 0 → XMM8; result GPR slot 0 → RBX (after chunk 13b pool shrink).
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]: MOVD EBX, XMM8 at [14..19].
    const expected = inst.encMovdR32FromXmm(.rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[14 .. 14 + expected.len]);
}

test "compile: f32.reinterpret_i32 — MOVD XMM8, R10D (GPR→XMM bit-cast)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.reinterpret_i32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 → RBX (after chunk 13b pool shrink); FP slot 0 → XMM8.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After i32.const at [4..9] (5 bytes for EBX): MOVD XMM8, EBX at [9..14].
    const expected = inst.encMovdXmmFromR32(.xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[9 .. 9 + expected.len]);
}

test "compile: f32.load — emit MOVSS xmm_dst, [rax + rdx] after eff-addr/bounds-check" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 (idx) → R10; FP slot 0 (result) → XMM8.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify the f32.load handler emits MOVSS XMM8, [RAX + RDX]
    // somewhere in the byte stream after the bounds prologue.
    const expected = inst.encMovssMovsdMemBaseIdx(.f32, false, .xmm8, .rax, .rdx);
    try testing.expect(std.mem.find(u8, out.bytes, expected.slice()) != null);
}

test "compile: f64.store — emit MOVSD [rax+rdx], xmm_src + bounds prologue with size=8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // i32.const 0 (idx) ; f64.const 1.0 (val) ; f64.store 0 ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.store", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 (idx) → R10; FP slot 1 (val) → XMM9.
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify the f64.store emits MOVSD [RAX+RDX], XMM9.
    const expected = inst.encMovssMovsdMemBaseIdx(.f64, true, .xmm9, .rax, .rdx);
    try testing.expect(std.mem.find(u8, out.bytes, expected.slice()) != null);
    // Verify the LEA bounds-check uses access_size=8 (the disp8
    // immediate in encLeaR64BaseDisp8 is the access_size byte).
    // Search for an LEA that has 8 as its disp byte; rough check
    // by looking for the LEA opcode + ModRM + disp8=0x08 sequence.
    // (The encoder is encLeaR64BaseDisp8(.rcx, .rdx, 8).)
    const expected_lea = inst.encLeaR64BaseDisp8(.rcx, .rdx, 8);
    try testing.expect(std.mem.find(u8, out.bytes, expected_lea.slice()) != null);
}

test "compile: i32.trunc_f32_u — Wasm 1.0 trapping unsigned via .q-trick" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const neg_one = inst.encMovImm32W(.rax, 0xBF800000);
    const upper = inst.encMovImm32W(.rax, 0x4F800000);
    // dst slot 0 → RBX after chunk 13b pool shrink.
    const cvt = inst.encCvttScalar2Int(.f32, true, .rbx, .xmm8);
    try testing.expect(std.mem.find(u8, out.bytes, neg_one.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, cvt.slice()) != null);
}

test "compile: i64.trunc_f64_u — Wasm 1.0 trapping with 2^63 split path" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_f64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const neg_one = inst.encMovImm64Q(.rax, 0xBFF0000000000000);
    const upper = inst.encMovImm64Q(.rax, 0x43F0000000000000);
    const split = inst.encMovImm64Q(.rax, 0x43E0000000000000);
    const subss = inst.encSseScalarBinary(.f64, 0x5C, .xmm6, .xmm7);
    const sign = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expect(std.mem.find(u8, out.bytes, neg_one.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, split.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, subss.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, sign.slice()) != null);
}

test "compile: i32.trunc_f32_s — Wasm 1.0 trapping; NaN/upper/lower → bounds_fixups" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0f
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
    // Verify presence of the 3 thresholds + CVTTSS2SI in the
    // emitted byte stream (full layout asserted via opcode+
    // boundary checks rather than every offset).
    const upper = inst.encMovImm32W(.rax, 0x4F000000); // 2^31
    const lower = inst.encMovImm32W(.rax, 0xCF000000); // -2^31
    // dst slot 0 → RBX after chunk 13b pool shrink.
    const cvt = inst.encCvttScalar2Int(.f32, false, .rbx, .xmm8);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, lower.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, cvt.slice()) != null);
}

test "compile: i64.trunc_sat_f32_u — 2^63 split path with SUBSS + sign-bit OR" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify a few key encoder outputs are present (full byte
    // sequence is too long to assert exhaustively).
    // Find threshold MOV (0x5F800000 for 2^64 f32) and the SUBSS
    // op in the high path.
    const threshold_max = inst.encMovImm32W(.rax, 0x5F800000);
    const threshold_split = inst.encMovImm32W(.rax, 0x5F000000);
    // Also verify SUBSS XMM6, XMM7 in the high path.
    const subss = inst.encSseScalarBinary(.f32, 0x5C, .xmm6, .xmm7);
    // OR RBX, RCX (full 64-bit) for the sign-bit restore.
    // dst slot 0 → RBX after chunk 13b pool shrink.
    const or_q = inst.encOrRR(.q, .rbx, .rcx);
    // MOVABS RBX, UINT64_MAX in the max path.
    const max_mov = inst.encMovImm64Q(.rbx, 0xFFFFFFFFFFFFFFFF);
    const bytes = out.bytes;
    try testing.expect(std.mem.find(u8, bytes, threshold_max.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, threshold_split.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, subss.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, or_q.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, max_mov.slice()) != null);
}

test "compile: i32.trunc_sat_f32_u — UCOMI/JP + clamp paths + CVTTSS2SI .q form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]:
    //   [14..18] UCOMISS XMM8, XMM8     (4 bytes; REX.R+B)
    //   [18..24] JP rel32 zero_path     (6 bytes)
    //   [24..27] XORPS XMM7, XMM7       (3 bytes; no prefix, no REX)
    //   [27..31] UCOMISS XMM8, XMM7     (4 bytes; REX.R only)
    //   [31..37] JBE rel32 zero_path    (6 bytes)
    //   [37..42] MOV EAX, 0x4F800000    (5 bytes; no REX)
    //   [42..46] MOVD XMM7, EAX         (4 bytes; no REX)
    //   [46..50] UCOMISS XMM8, XMM7     (4 bytes)
    //   [50..56] JAE rel32 max_path     (6 bytes)
    //   [56..61] CVTTSS2SI RBX, XMM8 .q (5 bytes; slot 0 = RBX after chunk 13b)
    //   [61..66] JMP rel32 done         (5 bytes)
    //   zero_path at 66
    const expected_xorps = inst.encSsePackedBinary(.f32, 0x57, .xmm7, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorps.slice(), out.bytes[24 .. 24 + expected_xorps.len]);
    const expected_thresh = inst.encMovImm32W(.rax, 0x4F800000);
    try testing.expectEqualSlices(u8, expected_thresh.slice(), out.bytes[37 .. 37 + expected_thresh.len]);
    const expected_cvt = inst.encCvttScalar2Int(.f32, true, .rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[56 .. 56 + expected_cvt.len]);
    // JP/JBE/JAE rel32 opcode bytes (disps patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[18]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[19]);
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[31]);
    try testing.expectEqual(@as(u8, 0x86), out.bytes[32]); // Jcc.be = 6
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[50]);
    try testing.expectEqual(@as(u8, 0x83), out.bytes[51]); // Jcc.ae = 3
}

test "compile: i32.trunc_sat_f32_s — CVTTSS2SI + CMP INT_MIN + branch saturation" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // FP slot 0 → XMM8; result GPR slot 0 → RBX (after chunk 13b pool shrink).
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]:
    //   [14..19] CVTTSS2SI EBX, XMM8      (5 bytes; F3 + REX + 0F + 2C + ModRM)
    //   [19..25] CMP EBX, 0x80000000     (6 bytes; 81 + ModRM + imm32 — no REX needed for RBX)
    //   [25..31] JNE rel32 (placeholder) (6 bytes)
    //   ...
    const expected_cvt = inst.encCvttScalar2Int(.f32, false, .rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[14 .. 14 + expected_cvt.len]);
    const expected_cmp = inst.encCmpRImm32(.rbx, 0x80000000);
    try testing.expectEqualSlices(u8, expected_cmp.slice(), out.bytes[19 .. 19 + expected_cmp.len]);
    // JNE / JP / JBE rel32 opcode bytes (disps patched at end-of-emit).
    // Offsets shift by -1 vs pre-13b: CMP imm32 saves a REX byte for RBX.
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[25]);
    try testing.expectEqual(@as(u8, 0x85), out.bytes[26]); // Jcc.ne = 5
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[35]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[36]); // Jcc.p = A
    const expected_xorps = inst.encSsePackedBinary(.f32, 0x57, .xmm7, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorps.slice(), out.bytes[41 .. 41 + expected_xorps.len]);
}

test "compile: i64.trunc_sat_f64_s — CVTTSD2SI .q + i64 sentinel via MOVABS+CMP r/r" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f64_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f64.const at [4..19]:
    //   [19..24]  CVTTSD2SI RBX, XMM8 (5 bytes; F2 + REX.W+R + 0F + 2C + ModRM 0xD8)
    //   [24..34]  MOVABS RCX, INT_MIN_i64 (10 bytes)
    //   [34..37]  CMP RBX, RCX (3 bytes; REX.W + 39 + ModRM) — slot 0 = RBX after chunk 13b
    const expected_cvt = inst.encCvttScalar2Int(.f64, true, .rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[19 .. 19 + expected_cvt.len]);
    const expected_min = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_min.slice(), out.bytes[24 .. 24 + expected_min.len]);
    const expected_cmp = inst.encCmpRR(.q, .rbx, .rcx);
    try testing.expectEqualSlices(u8, expected_cmp.slice(), out.bytes[34 .. 34 + expected_cmp.len]);
}

test "compile: f32.convert_i32_u — CVTSI2SS XMM8, R10 (REX.W on i32 src for zero-extend trick)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF }); // u32 max
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // i32.const 0xFFFFFFFF at [4..9]; CVTSI2SS XMM8, RBX (i64 form) at [9..14].
    // (slot 0 = RBX after chunk 13b pool shrink — i32.const is 5 bytes.)
    const expected = inst.encCvtsi2Scalar(.f32, true, .xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[9 .. 9 + expected.len]);
}

test "compile: f32.convert_i64_u — branch-based slow-path emit" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // i32.const placeholder for i64 source (synthetic; emit doesn't validate types).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // i32.const at [4..9] (slot 0 = RBX after chunk 13b pool shrink). Then:
    //   [9..12]  TEST RBX, RBX            (3 bytes; REX.W = 48 + 85 + DB)
    //   [12..18] JS rel32 placeholder     (6 bytes)
    //   [18..23] CVTSI2SS XMM8, RBX i64   (5 bytes; F3 + REX.W+R + 0F 2A C3)
    //   [23..28] JMP rel32 to end         (5 bytes)
    //   slow_path at 28:
    const expected_test = inst.encTestRR(.q, .rbx, .rbx);
    try testing.expectEqualSlices(u8, expected_test.slice(), out.bytes[9 .. 9 + expected_test.len]);
    // JS rel32 opcode bytes (disp patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[12]);
    try testing.expectEqual(@as(u8, 0x88), out.bytes[13]); // Jcc.s = 8
    const expected_pos_cvt = inst.encCvtsi2Scalar(.f32, true, .xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected_pos_cvt.slice(), out.bytes[18 .. 18 + expected_pos_cvt.len]);
    // JMP rel32 opcode at 23.
    try testing.expectEqual(@as(u8, 0xE9), out.bytes[23]);
    // Slow path starts at 28: MOV RAX, RBX (3 bytes; REX.W = 48 89 D8)
    const expected_mov_rax = inst.encMovRR(.q, .rax, .rbx);
    try testing.expectEqualSlices(u8, expected_mov_rax.slice(), out.bytes[28 .. 28 + expected_mov_rax.len]);
    // After slow path: MOV RAX (3) + SHR RAX (4) + MOV RCX (3) + AND RCX (4) + OR (3) +
    //                  CVTSI2SS (5) + ADDSS dst,dst (5) = 27 bytes. Slow path ends at 28+27=55.
    // Verify ADDSS is the final slow-path insn (5 bytes).
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm8, .xmm8);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[50 .. 50 + expected_addss.len]);
    // Verify JS rel32 disp points at slow_path (28).
    const js_disp = std.mem.readInt(i32, out.bytes[14..18], .little);
    try testing.expectEqual(@as(i32, 28 - 12 - 6), js_disp);
    // Verify JMP rel32 disp points at end (55).
    const jmp_disp = std.mem.readInt(i32, out.bytes[24..28], .little);
    try testing.expectEqual(@as(i32, 55 - 23 - 5), jmp_disp);
}

test "compile: f32.convert_i32_s — CVTSI2SS XMM8, R10D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
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
    // After i32.const at [4..9] (slot 0 = RBX, 5 bytes after chunk 13b):
    // CVTSI2SS XMM8, EBX at [9..14].
    const expected = inst.encCvtsi2Scalar(.f32, false, .xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[9 .. 9 + expected.len]);
}

test "compile: f32.min — branch-based emit (UCOMISS + JP/JE + 3 paths)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.min" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body offsets after 2× f32.const (10+10=20 bytes) at 4..24:
    //   [24..28] UCOMISS XMM8, XMM9     (4 bytes)
    //   [28..34] JP rel32 (placeholder) (6 bytes)
    //   [34..40] JE rel32 (placeholder) (6 bytes)
    //   [40..44] MOVAPS XMM10, XMM8     (4 bytes)
    //   [44..49] MINSS XMM10, XMM9      (5 bytes; F3 + REX + 0F + 5D + ModRM)
    //   [49..54] JMP rel32              (5 bytes)
    //   [54..58] MOVAPS XMM10, XMM8     (eq path)
    //   [58..62] ORPS XMM10, XMM9       (4 bytes)
    //   [62..67] JMP rel32              (5 bytes)
    //   [67..71] MOVAPS XMM10, XMM8     (nan path)
    //   [71..76] ADDSS XMM10, XMM9      (5 bytes)
    const expected_ucomi = inst.encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[24 .. 24 + expected_ucomi.len]);
    // JP / JE rel32 disps are patched; assert opcode bytes only.
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[28]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[29]); // Jcc.p = A
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[34]);
    try testing.expectEqual(@as(u8, 0x84), out.bytes[35]); // Jcc.e = 4
    const expected_minss = inst.encSseScalarBinary(.f32, 0x5D, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_minss.slice(), out.bytes[44 .. 44 + expected_minss.len]);
    const expected_orps = inst.encSsePackedBinary(.f32, 0x56, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_orps.slice(), out.bytes[58 .. 58 + expected_orps.len]);
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[71 .. 71 + expected_addss.len]);

    // Verify JP rel32 disp is patched correctly to point at nan_path (byte 67).
    const jp_disp = std.mem.readInt(i32, out.bytes[30..34], .little);
    try testing.expectEqual(@as(i32, 67 - 28 - 6), jp_disp);
    // Verify JE rel32 disp points at eq_path (byte 54).
    const je_disp = std.mem.readInt(i32, out.bytes[36..40], .little);
    try testing.expectEqual(@as(i32, 54 - 34 - 6), je_disp);
}

test "compile: f64.max — eq path uses ANDPD, common uses MAXSD" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.max" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f64.const (15+15=30 bytes) at body 4..34:
    //   [34..39] UCOMISD XMM8, XMM9   (5 bytes: 66 prefix + REX)
    //   [39..45] JP rel32             (6 bytes)
    //   [45..51] JE rel32             (6 bytes)
    //   [51..55] MOVAPS XMM10, XMM8   (4 bytes; common path)
    //   [55..60] MAXSD XMM10, XMM9    (5 bytes; F2 + REX + 0F + 5F + ModRM)
    //   [60..65] JMP rel32 (common)
    //   [65..69] MOVAPS XMM10, XMM8   (eq path)
    //   [69..74] ANDPD XMM10, XMM9    (5 bytes; 66 + REX + 0F + 54 + ModRM)
    const expected_ucomi = inst.encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[34 .. 34 + expected_ucomi.len]);
    const expected_maxsd = inst.encSseScalarBinary(.f64, 0x5F, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_maxsd.slice(), out.bytes[55 .. 55 + expected_maxsd.len]);
    const expected_andpd = inst.encSsePackedBinary(.f64, 0x54, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_andpd.slice(), out.bytes[69 .. 69 + expected_andpd.len]);
}

test "compile: f32.copysign — bit-twiddle via RAX/RDX/RCX scratches" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xBF800000 }); // -1.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f32.const (10+10=20 bytes) at body offset 4..24:
    //   [24..29] MOVD EAX, XMM8        (5 bytes)
    //   [29..34] MOVD EDX, XMM9        (5 bytes)
    //   [34..39] MOV ECX, 0x7FFFFFFF   (5 bytes)
    //   [39..41] AND EAX, ECX          (2 bytes)
    //   [41..46] MOV ECX, 0x80000000   (5 bytes)
    //   [46..48] AND EDX, ECX          (2 bytes)
    //   [48..50] OR EAX, EDX           (2 bytes)
    //   [50..55] MOVD XMM10, EAX       (5 bytes)
    const expected_movd_lhs = inst.encMovdR32FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, expected_movd_lhs.slice(), out.bytes[24 .. 24 + expected_movd_lhs.len]);
    const expected_mag_mask = inst.encMovImm32W(.rcx, 0x7FFFFFFF);
    try testing.expectEqualSlices(u8, expected_mag_mask.slice(), out.bytes[34 .. 34 + expected_mag_mask.len]);
    const expected_or = inst.encOrRR(.d, .rax, .rdx);
    try testing.expectEqualSlices(u8, expected_or.slice(), out.bytes[48 .. 48 + expected_or.len]);
    const expected_final_movd = inst.encMovdXmmFromR32(.xmm10, .rax);
    try testing.expectEqualSlices(u8, expected_final_movd.slice(), out.bytes[50 .. 50 + expected_final_movd.len]);
}

test "compile: f64.copysign — same shape with .q widths and MOVABS masks" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0xBFF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f64.const (15+15=30 bytes) at body offset 4..34:
    //   [34..39] MOVQ RAX, XMM8        (5 bytes; 66 + REX.W + REX.R + ...)
    //   [39..44] MOVQ RDX, XMM9
    //   [44..54] MOVABS RCX, 0x7FFF... (10 bytes)
    //   [54..57] AND RAX, RCX          (3 bytes; REX.W)
    //   [57..67] MOVABS RCX, 0x8000... (10 bytes)
    //   [67..70] AND RDX, RCX
    //   [70..73] OR RAX, RDX
    //   [73..78] MOVQ XMM10, RAX
    const expected_movq_lhs = inst.encMovqR64FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, expected_movq_lhs.slice(), out.bytes[34 .. 34 + expected_movq_lhs.len]);
    const expected_mag = inst.encMovImm64Q(.rcx, 0x7FFFFFFFFFFFFFFF);
    try testing.expectEqualSlices(u8, expected_mag.slice(), out.bytes[44 .. 44 + expected_mag.len]);
    const expected_sign = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_sign.slice(), out.bytes[57 .. 57 + expected_sign.len]);
    const expected_movq_dst = inst.encMovqXmmFromR64(.xmm10, .rax);
    try testing.expectEqualSlices(u8, expected_movq_dst.slice(), out.bytes[73 .. 73 + expected_movq_dst.len]);
}

test "compile: f32.sqrt — SQRTSS XMM9, XMM8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40800000 }); // 4.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.sqrt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]: SQRTSS XMM9, XMM8 at [14..19].
    const expected = inst.encSseScalarBinary(.f32, 0x51, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[14 .. 14 + expected.len]);
}

test "compile: f64.ceil — ROUNDSD XMM9, XMM8, mode=2" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF80000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.ceil" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f64.const at [4..19]: ROUNDSD XMM9, XMM8, 2 at [19..26].
    const expected = inst.encRoundsd(.xmm9, .xmm8, 2);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[19 .. 19 + expected.len]);
}

test "compile: f32.abs — mask materialisation + MOVAPS + ANDPS" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xBF800000 }); // -1.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.abs" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]:
    //   [14..19] MOV EAX, 0x7FFFFFFF (5 bytes)
    //   [19..23] MOVD XMM7, EAX      (4 bytes; no REX since xmm7 < xmm8 and rax < r8)
    //   [23..27] MOVAPS XMM9, XMM8   (4 bytes; REX.R+REX.B)
    //   [27..31] ANDPS XMM9, XMM7    (4 bytes; REX.R only since xmm7 < xmm8)
    const expected_mask = inst.encMovImm32W(.rax, 0x7FFFFFFF);
    try testing.expectEqualSlices(u8, expected_mask.slice(), out.bytes[14 .. 14 + expected_mask.len]);
    const expected_andps = inst.encSsePackedBinary(.f32, 0x54, .xmm9, .xmm7);
    try testing.expectEqualSlices(u8, expected_andps.slice(), out.bytes[27 .. 27 + expected_andps.len]);
}

test "compile: f64.neg — XORPD with sign-bit mask" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.neg" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f64.const at [4..19]:
    //   [19..29] MOVABS RAX, 0x80...0 (10 bytes)
    //   [29..34] MOVQ XMM7, RAX       (5 bytes)
    //   [34..38] MOVAPS XMM9, XMM8    (4 bytes)
    //   [38..43] XORPD XMM9, XMM7     (5 bytes; 66 prefix + REX.R + 0F 57 + ModRM)
    const expected_mask = inst.encMovImm64Q(.rax, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_mask.slice(), out.bytes[19 .. 19 + expected_mask.len]);
    const expected_xorpd = inst.encSsePackedBinary(.f64, 0x57, .xmm9, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorpd.slice(), out.bytes[38 .. 38 + expected_xorpd.len]);
}

test "compile: f32.lt — UCOMISS swapped + SETA + MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.lt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Slots 0,1 → XMM8, XMM9; slot 2 (i32 result) → RBX (after chunk 13b).
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f32.const (10+10=20 bytes) at body offset 4..24. With slot 0
    // for the (FP-bank-only) f32.const operands the FP encoding is unchanged
    // — only the i32 result bank moves from R10 → RBX, and SETcc/MOVZX with
    // RBX still need a forced 0x40 REX byte for BL access, so byte counts and
    // the SETA offset (28) are preserved.
    //   [24..28] UCOMISS XMM9, XMM8 (swap; 4 bytes: REX 45 0F 2E C8)
    //   [28..32] SETA BL (4 bytes: 40 0F 97 C3)
    //   [32..36] MOVZX EBX, BL (4 bytes: 40 0F B6 DB)
    const expected_ucomiss = inst.encUcomiss(.xmm9, .xmm8); // swapped: a=rhs, b=lhs
    try testing.expectEqualSlices(u8, expected_ucomiss.slice(), out.bytes[24 .. 24 + expected_ucomiss.len]);
    const expected_seta = inst.encSetccR(.a, .rbx);
    try testing.expectEqualSlices(u8, expected_seta.slice(), out.bytes[28 .. 28 + expected_seta.len]);
}

test "compile: f32.eq — UCOMISS + SETNP/SETE + AND combine" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.eq" });
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
    // After 2× f32.const (20 bytes) at body offset 4..24:
    //   [24..28] UCOMISS XMM8, XMM9   (4 bytes; no swap for eq)
    //   [28..32] SETNP AL             (4 bytes: 40 0F 9B C0)
    //   [32..36] MOVZX EAX, AL        (4 bytes: 40 0F B6 C0)
    //   [36..40] SETE BL              (4 bytes: 40 0F 94 C3) — slot 0 = RBX after chunk 13b
    //   [40..44] MOVZX EBX, BL
    //   [44..46] AND EBX, EAX         (2 bytes: 21 C3 — no REX needed)
    const expected_ucomiss = inst.encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomiss.slice(), out.bytes[24 .. 24 + expected_ucomiss.len]);
    const expected_setnp = inst.encSetccR(.np, .rax);
    try testing.expectEqualSlices(u8, expected_setnp.slice(), out.bytes[28 .. 28 + expected_setnp.len]);
    const expected_and = inst.encAndRR(.d, .rbx, .rax);
    try testing.expectEqualSlices(u8, expected_and.slice(), out.bytes[44 .. 44 + expected_and.len]);
}

test "compile: f64.gt — UCOMISD + SETA + MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.gt" });
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
    // 2× f64.const = 30 bytes at [4..34]. Then at [34..]:
    //   UCOMISD XMM8, XMM9 (5 bytes; 66 prefix + REX)
    const expected_ucomisd = inst.encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomisd.slice(), out.bytes[34 .. 34 + expected_ucomisd.len]);
}

test "compile: f32.add stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.add" }); // missing rhs
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: call_indirect — out-of-range type_idx → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: call N — out-of-range callee_idx → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{sig}; // only idx 0 exists
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u8{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &func_sigs, &.{}));
}

test "compile: i32.wrap_i64 with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: i32.add with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" }); // missing 2nd operand
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

// FP / i64 -aware function-level `end` return marshal (D-032).
// `f32.const` / `f64.const` push their value onto an XMM slot;
// `i64.extend_i32_u` pushes a full 64-bit GPR result. The
// pre-fix end handler emitted `MOV EAX, r32(slotToReg(slot))`
// for *every* result type, which (a) read the wrong physical
// reg for FP results (fpSlotToReg ≠ slotToReg for the same
// slot id) and (b) truncated i64 to i32 by using .d width.
// The fix dispatches on `func.sig.results[0]`:
//   .i32/.funcref/.externref → MOV EAX, src   (.d, current)
//   .i64                     → MOV RAX, src   (.q, full width)
//   .f32/.f64                → MOVAPS XMM0, src_xmm
//   .v128                    → UnsupportedOp (deferred)
// MOVAPS works for both f32 and f64: x86_64 returns FP values in
// XMM0 with full register width, so a single 128-bit register
// move is sufficient (vs ARM64's FMOV S0/D0 size-discriminated
// move). See ARM64 reference at arm64/emit.zig:475-503.

test "compile: f32.const → end emits MOVAPS XMM0, XMM8 (FP-aware return marshal)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // FP slot 0 → XMM8.
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..4]   prologue: PUSH RBP ; MOV RBP, RSP
    //   [4..14]  f32.const: MOV EAX, bits ; MOVD XMM8, EAX
    //   [14..18] end FP marshal: MOVAPS XMM0, XMM8 (4 bytes)
    //   [18..20] epilogue: POP RBP ; RET
    const expected_movaps = inst.encMovapsXmmXmm(.xmm0, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[14 .. 14 + expected_movaps.len]);
    try testing.expectEqual(@as(usize, 20), out.bytes.len);
}

test "compile: f64.const → end emits MOVAPS XMM0, XMM8 (same MOVAPS works for f64)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const bits: u64 = 0x3FF0000000000000; // 1.0
    try f.instrs.append(testing.allocator, .{
        .op = .@"f64.const",
        .payload = @truncate(bits),
        .extra = @truncate(bits >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout:
    //   [0..4]   prologue
    //   [4..19]  f64.const: MOVABS RAX, bits ; MOVQ XMM8, RAX
    //   [19..23] end FP marshal: MOVAPS XMM0, XMM8
    //   [23..25] epilogue
    const expected_movaps = inst.encMovapsXmmXmm(.xmm0, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[19 .. 19 + expected_movaps.len]);
    try testing.expectEqual(@as(usize, 25), out.bytes.len);
}

test "compile: i64-result end emits MOV RAX, src (.q full width avoids truncation)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 → RBX (after chunk 13b pool shrink). Both vregs share slot id 0.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (slot 0 = RBX after chunk 13b — i32.const + self-MOV both shed REX):
    //   [0..4]   prologue
    //   [4..9]   i32.const: MOV EBX, imm32 (B8+rd + 4-byte imm = 5 bytes)
    //   [9..11]  i64.extend_i32_u: MOV EBX, EBX (.d, 2 bytes — no REX)
    //   [11..14] end i64 marshal: MOV RAX, RBX (.q, 3 bytes; REX.W = 48 89 D8)
    //   [14..16] epilogue
    const expected_movrr = inst.encMovRR(.q, .rax, .rbx);
    try testing.expectEqualSlices(u8, expected_movrr.slice(), out.bytes[11 .. 11 + expected_movrr.len]);
    try testing.expectEqual(@as(usize, 16), out.bytes.len);
}

test "compile: nop emits no body bytes (between prologue and epilogue)" {
    // Wasm spec §4.4.6.2 — nop has zero machine effect.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"nop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u8{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..4] prologue: PUSH RBP ; MOV RBP, RSP
    //   [4..6] epilogue: POP RBP ; RET
    try testing.expectEqual(@as(usize, 6), out.bytes.len);
}

test "compile: drop pops vreg without machine bytes (i32.const, drop, end)" {
    // Wasm spec §4.4.4 — drop consumes top operand without storage.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    //   [0..4]   prologue
    //   [4..9]   i32.const: MOV EBX, 7 (5 bytes — B8+rd + 4-byte imm; no REX)
    //   no drop bytes
    //   [9..11]  epilogue: POP RBP ; RET (no marshal because results.len==0)
    try testing.expectEqual(@as(usize, 11), out.bytes.len);
}

test "compile: return mid-function (i32.const, return, end) emits MOV EAX + epilogue, then a second epilogue" {
    // Wasm spec §4.4.7 — return marshals + exits. The trailing
    // function-level `end` emits a second (dead) epilogue. Both
    // epilogues are equivalent (no fixup mechanism on x86_64).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"return" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    //   [0..4]   prologue: PUSH RBP ; MOV RBP, RSP (4 bytes)
    //   [4..9]   i32.const: MOV EBX, imm (5 bytes)
    //   [9..11]  return marshal: MOV EAX, EBX (2 bytes — .d MovRR, no REX)
    //   [11..13] return epilogue: POP RBP ; RET (2 bytes)
    //   end (function-level):
    //     pushed_vregs.len > 0 still — emit second marshal MOV EAX, EBX
    //     [13..15] (2 bytes)
    //     [15..17] second epilogue: POP RBP ; RET (2 bytes)
    const expected_marshal = inst.encMovRR(.d, abi.return_gpr, .rbx);
    try testing.expectEqualSlices(u8, expected_marshal.slice(), out.bytes[9 .. 9 + expected_marshal.len]);
    // First RET at byte 12
    try testing.expectEqual(@as(u8, 0xC3), out.bytes[12]);
    // Total length: 4 + 5 + 2 + 2 + 2 + 2 = 17 bytes
    try testing.expectEqual(@as(usize, 17), out.bytes.len);
}

test "compile: i64.add emits ADD .q (REX.W) — 64-bit width preserved" {
    // Wasm spec §4.4.1.1 (i64.add). Tests the .q-form path:
    // MOV dst, lhs (.q) + ADD dst, rhs (.q) both carry REX.W.
    // Without REX.W (= 32-bit) the upper 32 bits of the result
    // would be truncated, silently mis-computing values that
    // exceed UINT32_MAX.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 2, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Slot map (after chunk 13b pool shrink): vreg 0 → RBX (slot 0),
    // vreg 1 → R12 (slot 1), vreg 2 reuses slot 0 → RBX.
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // i64.add lowers to: MOV RBX, RBX (skip — same reg) + ADD RBX, R12 (.q).
    // After 4-byte prologue + 2× MOVABS (10 each) = byte 24 the
    // ADD appears with REX.W set (encoded as 0x4C — REX.W+R since src=R12
    // needs REX.R; dst=RBX low does not need REX.B).
    const add_off = 4 + 10 + 10;
    const expected_add = inst.encAddRR(.q, .rbx, .r12);
    try testing.expectEqualSlices(u8, expected_add.slice(), out.bytes[add_off .. add_off + expected_add.len]);
    // First byte of ADD must include REX.W (bit 3 of low nibble).
    try testing.expect((out.bytes[add_off] & 0x08) != 0);
}

test "compile: i64.clz emits LZCNT .q (REX.W; F3 prefix) — 64-bit count" {
    // Wasm spec §4.4.1.4 (i64.clz). Result is i64 (count 0..64);
    // .q form distinguishes from .d form which would max at 32.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // vreg 0 → RBX (slot 0); vreg 1 (result) → R12 (slot 1) after chunk 13b.
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After prologue (4) + MOVABS RBX (10) = byte 14: LZCNT R12, RBX (.q form).
    const lzcnt_off = 14;
    const expected_lzcnt = inst.encLzcntR64(.r12, .rbx);
    try testing.expectEqualSlices(u8, expected_lzcnt.slice(), out.bytes[lzcnt_off .. lzcnt_off + expected_lzcnt.len]);
}

test "compile: i64.const emits MOVABS r64, imm64 (10 bytes)" {
    // Wasm spec §4.4.1.1 (i64.const). Verifies the full 64-bit
    // immediate path: high word from ins.extra, low word from
    // ins.payload, recombined and emitted as a single MOVABS.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const value: u64 = 0x0CABBA6E0BA66A6E; // arbitrary 64-bit literal
    try f.instrs.append(testing.allocator, .{
        .op = .@"i64.const",
        .payload = @truncate(value),
        .extra = @truncate(value >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // GPR slot 0 → RBX after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..4]   prologue: PUSH RBP ; MOV RBP, RSP
    //   [4..14]  i64.const: MOVABS RBX, imm64 (10 bytes; REX.W + B8+rd + 8-byte imm)
    //   [14..17] end i64 marshal: MOV RAX, RBX (.q, 3 bytes; 48 89 D8)
    //   [17..19] epilogue: POP RBP ; RET
    const expected_movabs = inst.encMovImm64Q(.rbx, value);
    try testing.expectEqualSlices(u8, expected_movabs.slice(), out.bytes[4 .. 4 + expected_movabs.len]);
    try testing.expectEqual(@as(usize, 19), out.bytes.len);
}

test "compile: unreachable emits JMP rel32 + trap stub patches disp to trap_byte" {
    // Wasm spec §4.4.6.1 — unreachable traps unconditionally.
    // Layout (no params, no locals, no result):
    //   [0..1]   prologue: PUSH RBP (1 byte)
    //   [1..4]   prologue: MOV RBP, RSP (3 bytes)
    //   [4..9]   unreachable: JMP rel32 placeholder (5 bytes)
    //   [9..11]  end-handler: POP RBP ; RET (no marshal because results.len==0)
    //   [11..]   trap stub: MOV [R15+trap_off], 1 ; XOR EAX,EAX ; POP RBP ; RET
    // Note: end-handler runs before the trap-stub patch loop, but
    // because there's no `uses_runtime_ptr` in this test, R15 is
    // not loaded — the trap stub's MOV [R15+...] would crash if
    // taken at runtime. This test only verifies the JMP disp32
    // gets patched to point at the trap stub byte; the actual
    // execution-time correctness is validated by the spec_assert
    // gate on x86_64 hosts (which uses uses_runtime_ptr=true via
    // memory ops). Here we just check the linker-visible byte
    // shape.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"unreachable" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u8{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // JMP rel32 starts at byte 4 (just after PUSH RBP + MOV RBP,RSP = 4 bytes prologue).
    try testing.expectEqual(@as(u8, 0xE9), out.bytes[4]);
    // Read patched disp32 and verify it points at trap_byte (= start
    // of trap stub, just after end-handler RET).
    const disp = std.mem.readInt(i32, out.bytes[5..9], .little);
    const jmp_at: i32 = 4;
    const target_abs: i32 = jmp_at + 5 + disp;
    // trap_byte should be the byte right after the end-handler RET.
    // end-handler is at [9..11] (POP RBP, RET) so trap stub starts at 11.
    try testing.expectEqual(@as(i32, 11), target_abs);
}

test "compile: v128-result end → UnsupportedOp (v128 marshalling deferred)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.v128} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // v128 producer ops are not yet implemented; reuse f32.const
    // to push an FP slot whose result_kind discriminator forces
    // the end handler down the v128 arm. The test asserts the
    // end handler refuses unknown-width returns rather than
    // silently emitting truncating MOV EAX bytes.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}
