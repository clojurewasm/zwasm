# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 7 IN-PROGRESS** (JIT v1 ARM64 baseline).
- **Last commit**: `3c89984` — §9.7 / 7.2 land: `src/jit_arm64/inst.zig`
  (RET/MOVZ/MOVK/ADD imm/SUB imm/ADD reg/SUB reg/LDR/STR/BR
  encoders, all bit-patterns cross-checked) + `src/jit_arm64/abi.zig`
  (AAPCS64 register inventory + slotToReg mapper). All hosts green.
- **Next task**: §9.7 / 7.3 — `src/jit_arm64/emit.zig` (ZIR →
  ARM64 emit pass producing function bodies; consumes regalloc
  slots from §9.7 / 7.1 + ABI from §9.7 / 7.2).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.7 / 7.3 (jit_arm64 emit pass)

Per ROADMAP §9.7 exit criterion: `src/jit_arm64/emit.zig`
produces AAPCS64-correct function bodies. Walks a lowered
`ZirFunc` (with `loop_info` + `liveness` + regalloc Allocation
already populated) and emits a `[]u8` of fixed-width ARM64
instructions.

Phase-7 / 7.3 scope (smallest viable first slice — straight-line
arithmetic):

- Function prologue: STP fp, lr, [sp, #-16]! ; MOV fp, sp ;
  reserve frame slot space.
- Per ZirOp emitter table — table-of-fn-pointers indexed by
  ZirOp (mirrors `src/interp/dispatch_table.zig` pattern but
  for emit). Initial coverage: i32.const → MOVZ/MOVK; i32.add /
  sub / mul → ADD/SUB/MUL; local.get / local.set → LDR / STR;
  end → epilogue + RET.
- Function epilogue: LDP fp, lr, [sp], #16 ; RET.
- Stack-frame sizing from regalloc.Allocation.n_slots × 8 bytes
  (GPR width).

Plan:

1. Survey wasmtime/winch's `wasmtime/winch/src/isa/aarch64/`
   for the emit-table shape — mandatory per textbook_survey
   Guard 4. Output: `private/notes/p7-7.3-survey.md`.
2. `emit.zig` with `pub fn emit(allocator, *const ZirFunc,
   Allocation) ![]u8` doing prologue → per-instr table dispatch
   → epilogue.
3. Tests: emit a 3-instr `(func (result i32) i32.const 42 end)`
   ZirFunc, verify the produced bytes decode to a sensible
   AArch64 sequence (movz x0, #42 ; ret) by re-decoding via
   `inst.zig`'s bit patterns. Add an `(i32.add 1 2)` test for
   the binop path.
4. Three-host `zig build test-all`.

No execution-of-emitted-code on this iteration — that's §9.7 /
7.4's spec-test-via-JIT gate (requires mmap'ing the buffer
executable + branching into it).

Phase-7 outstanding (post 7.3): 7.4 spec test JIT / 7.5 40+
realworld JIT / 7.6 `interp == jit_arm64` differential /
7.7 wasmtime stdout (ADR-0010) / 7.8 ClojureWasm (ADR-0010) /
7.9 boundary audit / 7.10 phase tracker.

Carry-overs queued:
- §9.5: `no_hidden_allocations` zlinter (ADR-0009); validator.zig
  per-feature split (with §9.1 / 1.7); liveness control-flow +
  memory-op coverage; const-prop per-block (Phase-15);
  `sections.zig` (1073) soft-cap split.
- §9.6: `br-table-fuzzbug` multi-param `loop`; 10 SKIP-VALIDATOR
  realworld; 39 trap-mid-exec fixtures.

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their own
phase. Phase 6 (ADR-0008) absorbs them as part of the v1
conformance baseline; do NOT re-pick during Phase 5.

- **multivalue blocks (multi-param)**: `BlockType` needs to carry
  both params + results; `pushFrame` must consume params (Phase 2
  chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)
