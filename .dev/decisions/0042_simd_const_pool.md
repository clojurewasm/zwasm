---
name: SIMD const-pool design (i8x16.shuffle + v128.const codegen)
description: Hybrid post-emit fixup const-pool for storing 16-byte SIMD literals in JIT blocks
status: Accepted
date: 2026-05-09
---

# ADR-0042: SIMD const-pool design

## Status

Accepted (2026-05-09)

## Context

Wasm SIMD-128 has two ops that carry 16-byte literal data in the bytecode
stream (separate from the operand stack):

- `v128.const` — 16-byte literal pushed as a v128 value (MVP catalogue
  per ADR-0041).
- `i8x16.shuffle` — 16-byte shuffle-index immediate; each lane is a
  `u8` in 0..31 (validated at parse time per Wasm SIMD spec
  `check_simd_lane_index`).

§9.4 lower currently stores the immediate as a *byte offset into the
function's wasm body* in `ZirInstr.payload` (lower.zig:500-516). The
codegen path (per-arch `emit.zig`) does not have access to the wasm body
bytes, so retrieving the 16 bytes at emit time is impossible without
either:

1. Extending `ZirFunc` to carry the body bytes (invasive).
2. Building a per-function side-table at lower time (`simd_consts:
   ?[]const [16]u8`) that the codegen indexes via the instruction's
   payload.

§9.6/9.6-f-ii (i8x16.shuffle) and v128.const codegen are deferred via
debt entry **D-056** pending this ADR. The §9.6-close v1+OSS audit
(2026-05-09 Explore subagent fan-out, transcripts at
`private/notes/p9.5-9.6-simd-audit.md`) cross-checked cranelift /
wasmer / wasmtime approaches and recommended a specific design.

The audit specifically rejects MOVZ/MOVK chain materialisation
(8 MOVZ/MOVK + 2 INS = 10 instructions per 16-byte constant) as the
primary path because the per-shuffle / per-const cost is high and
~400 bytes of JIT block bloat per use site adds up.

The audit also rejects inlining the 16 bytes directly between
instructions (defeats single-pass discipline; needs backpatch).

## Decision

Adopt **hybrid const-pool with post-emit fixup**:

1. **Lower-time side table**: extend `ZirFunc` with
   `simd_consts: ?[]const [16]u8`. At lower time, for each
   `v128.const` and `i8x16.shuffle` opcode, copy the 16 bytes from
   the wasm body into a per-function `Lowerer.simd_consts:
   ArrayList([16]u8)` and store the array index in `ZirInstr.payload`
   (replacing the current body-offset-in-payload encoding). At
   `Lowerer.finish()` time, flush to `func.simd_consts`.

2. **Codegen-time emission**: at emit time, the handler retrieves
   the 16-byte literal via `func.simd_consts.?[ins.payload]`. The
   handler emits a placeholder `LDR Q<rt>, =<label>` (PC-relative
   literal load — single instruction, ARM64 §C7.2.198) with a
   placeholder `imm19` field, and records a fixup `(byte_offset,
   pool_slot_index)` for the linker / runner pass.

3. **Per-function const-pool**: at function emit close, the per-arch
   emit pass appends the unique 16-byte constants to the JIT byte
   buffer immediately after the function body (16-byte aligned).

4. **Fixup pass**: after function emit, walk the fixup list and
   patch each LDR-literal's `imm19` field to the final PC-relative
   offset. Both forward fixups (LDR before pool) and backward fixups
   (LDR after pool — unusual but possible if shuffle straddles the
   boundary) are handled by signed `imm19`.

5. **Single-pass discipline preserved**: the emit phase still walks
   ZirInstr in linear order; the fixup pass is bookkeeping over
   already-emitted bytes (no re-lowering).

Bundle v128.const + i8x16.shuffle codegen into a single chunk
(§9.6/9.6-f-ii implementation; both ops share the same simd_consts
+ fixup machinery).

## Alternatives considered

### Option B (Rejected — perf cost): MOVZ/MOVK materialisation chain

- 8 × MOVZ/MOVK per X-register pair (16 bytes total = 2 X regs) + 2
  INS V.D[k] = 10 instructions.
- No new infrastructure, but ~40-byte per-use cost vs. 4-byte
  LDR-literal + 16-byte pool entry.
- For a typical Wasm function with 0-2 shuffle/const ops, the absolute
  cost is small, but optimisation phase (Phase 15) would have to
  rewrite to const-pool anyway.
- Rejected: pay the const-pool infra cost once, not per-use forever.

### Option C (Rejected — discipline violation): Inline 16 bytes between instructions

- Embed the 16 bytes in the instruction stream right after the
  function body's last instruction, with a `B .+24` to skip them.
- Or interleave inline data with code (NEON `LDR` accepts arbitrary
  PC-relative offsets).
- Rejected: ARM64 distinguishes I-cache from D-cache; mixing data
  and code in the instruction stream requires explicit cache-flush
  discipline. Cranelift's separate const-pool placement (after
  function body) is the standard approach.

### Option D (Rejected — invasive): Extend ZirFunc with body bytes

- Add `body: []const u8` to ZirFunc so codegen can read the original
  16 bytes at the byte offset stored in payload.
- Rejected: mixes parser-stage state into post-lower IR; violates
  Zone 1 separation. Also complicates ZirFunc lifetime (who owns
  body bytes? lower returned, parser dropped).

## Consequences

### Positive

- Single LDR-literal per use site → minimal hot-path cost.
- Const-pool footprint amortises across multiple use sites of the
  same constant (linker can dedupe per-function or even globally).
- Aligns with cranelift's VCode constant infrastructure (familiar
  pattern for Wasm runtime engineers).
- Fixup machinery may extend later to other PC-relative needs (e.g.,
  trap stub return addresses, debug location records).

### Negative

- New ZirFunc field (`simd_consts`) — touches Phase 9 / 4 surface,
  but additive (Optional, defaults to `null`).
- Lower contract change: `ZirInstr.payload` for v128.const + i8x16.
  shuffle now means "index into func.simd_consts", not "byte offset
  into func.body". Callers must update; v128.const handler is not
  yet implemented (current state: would-fail-at-runtime), so no
  existing consumer breaks.
- Per-arch emit gains a fixup pass that runs after the linear emit
  walk. Existing fixups (e.g., branch targets) already use a
  similar pattern; this extends the same machinery.
- Per-function const-pool needs a 16-byte alignment boundary before
  the first pool entry. Padding bytes are zero-initialised (NOPs on
  ARM64 if executed by mistake; benign).

## Implementation chunk plan

§9.6/9.6-f-ii implementation chunk:

1. Add `simd_consts: ?[]const [16]u8` field to `ZirFunc` in
   `src/ir/zir.zig` (with init/deinit ownership at lower).
2. Update `src/ir/lower.zig` `emitPrefixFD` cases 12 (v128.const)
   and 13 (i8x16.shuffle) to:
   - Read the 16 bytes from `self.body`
   - Append to `Lowerer.simd_consts` (new field; `ArrayList([16]u8)`)
   - Store the array index in `ZirInstr.payload`
3. Add `inst_neon.zig` encoder: `encLdrLiteralQ(rt: Vn, imm19: i20) u32`.
4. Add `op_simd.zig` handlers:
   - `emitV128Const` — pop nothing; push v128 result. Records fixup;
     emits LDR-literal placeholder.
   - `emitI8x16Shuffle` — pop 2 v128 (lhs, rhs); push v128 result.
     For TBL 2-register form: emit copy-to-fixed-pair preamble
     (encMovV16B(31, rhs); encMovV16B(30, lhs)), then encTbl2Reg,
     where the indices come from a const-pool LDR-literal into a
     scratch V register. Per the SIMD audit's cross-check this is
     the pattern cranelift uses (modulo regalloc-pinned pair vs.
     copy-preamble).
5. Add fixup machinery to per-arch emit close (per-function const
   pool flush + LDR-literal imm19 patch).
6. Wire `v128.const` + `i8x16.shuffle` dispatch arms in
   `arm64/emit.zig` and `shape_tag` walker in `shared/regalloc.zig`.
7. Discharge D-056 with this commit; reference ADR-0042 in commit
   body.

## References

- D-056 (`.dev/debt.md`) — deferred entry naming the structural
  barrier this ADR resolves.
- Cranelift VCode constant + literal pool: wasmtime/cranelift/
  codegen/src/isa/aarch64/lower.isle:242-244 + machinst/isle.rs:
  417-420 (per `private/notes/p9-9.6-f-ii-shuffle-survey.md`,
  gitignored, 2026-05-09).
- v1-audit SIMD findings: `private/notes/p9.5-9.6-simd-audit.md`
  §5 (Const-Pool Design D-056 Forward Look) — recommends Option A
  (this ADR's decision).
- ADR-0041 (SIMD-128 design framing) — establishes shape-as-variant
  ZirOp catalogue + FP-class register pool reuse; this ADR extends
  that framework with const-pool plumbing.
- Arm IHI 0055 §C7.2.198 (LDR (literal, SIMD&FP)) — encoding for
  the LDR-literal-Q instruction.
