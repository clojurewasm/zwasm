# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 + D-055 + 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: hoist-branch-targets-as-pc, regalloc, coalescer).
5. `.dev/decisions/0031_zir_hoist_pass.md` (D-053 root-cause amend per 8a.6).
6. `.dev/optimisation_log.md` (F/R/O ledger; 8b adoption discipline).

## Current state — Phase 9 / §9.9/9.5-c-vii [x] (f32x4/f64x2 lane access); **§9.9/9.5-c-vii-mul NEXT**

§9.9/9.5-c-vii adds 4 NEON FP lane-access encoders (DUP-scalar
S/D + INS-element S/D, src lane 0) and 4 op_simd handlers wired
through new helper pair `emitV128ExtractLaneFp` /
`emitV128ReplaceLaneFp` (parallel to the int-side helpers; the
FP scalar resolves stay on SPILL-EXEMPT alongside the GPR ones).

i64x2.mul defers to 9.5-c-vii-mul because the multi-instr
synthesis (extract D-lanes via UMOV X / scalar 64-bit MUL /
insert via INS D from X) introduces a scratch-register
reservation — ADR-grade design choice that warrants its own
chunk per LOOP.md granularity.

Per LOOP.md chunk granularity, 9.5 row sub-split:
- 9.5-a/b/c-i…c-vii [x]: encoder foundation + shape-tag
  pipeline + Q-form spill + op_simd refactor + i32x4 lane
  access + ADD/SUB + MUL (16B/8H/4S) + int lane access B/H/D
  + FP lane access S/D.
- 9.5-c-vii-mul NEXT: i64x2.mul synthesis (extract X.D-lane /
  scalar MUL / insert X.D-lane sequence) + scratch-reg
  reservation convention.

Mac gates: zone ✓, file_size ✓, spill ✓, lint ✓; spec
212/0/20, wast 1158/0/0.

**§9.9/9.5-c-vii-mul NEXT** — i64x2.mul multi-instr synthesis.
Per lane k ∈ {0, 1}:
1. `UMOV X<scratch_a>, V<lhs>.D[k]` — `encUmovXFromD`
2. `UMOV X<scratch_b>, V<rhs>.D[k]`
3. `MUL X<scratch_c>, X<scratch_a>, X<scratch_b>` — scalar 64-bit
   MUL (need to verify presence of `encMulXX` in `inst.zig`; add
   if missing).
4. `INS V<result>.D[k], X<scratch_c>` — `encInsDFromX`

Scratch-reg reservation: candidates X16 / X17 (IP0 / IP1 — AAPCS64
intra-procedure scratch) or a fixed pair from the regalloc-
reserved range. Survey `gpr.zig` / `regalloc.zig` for existing
scratch conventions before introducing a new one (Step 0 task).

## Active task — §9.9/9.5-c-vii-mul: i64x2.mul synthesis **NEXT**

Single op, multi-instr synthesis. Estimated ~80 src + ~40 tests
(handler + scratch-reg reservation comment + two-lane unrolled
codegen test asserting 8 emitted words: 2× UMOV + 2× MUL + 2×
INS + 2× v128 spill load/store).

After 8b.4: 8b.5 (boundary audit_scaffolding) + 8b.6 (open
§9.9 inline + flip Phase Status).

## Closed §9.8b artefacts (for Phase 12 + Phase 15 reference)

- ADRs: 0035 (coalescer design) / 0036 (8b.1 scope down) /
  0037 (regalloc upgrade + Rev 2 discovery) / 0038 (class-
  aware deferral) / 0039 (.cwasm format + Rev 2 numeric
  correction) / 0040 (aggregate target revision)
- Lessons: `2026-05-09-greedy-local-already-does-reuse.md`
- Code: `src/ir/coalesce/pass.zig`, `src/engine/codegen/
  shared/regalloc.zig` LIFO free-pool, `src/engine/codegen/
  aot/{format, serialise, produce}.zig`, `src/cli/compile.zig`
- Surveys (gitignored): `private/notes/p8-8b{1,2,3}-*-
  survey.md`

After 8b.3: 8b.4 (≥10% aggregate; concentrated on 8b.3
contribution per ADR-0038), 8b.5 (Phase 8 boundary audit),
8b.6 (open §9.9).

## Closed §9.8b artefacts (for Phase 15 reference)

- ADR-0035 (post-regalloc slot-aliasing coalescer design)
- ADR-0036 (8b.1 scope downgrade)
- ADR-0037 (regalloc upgrade design + Revision 2 discovery)
- ADR-0038 (class-aware allocation deferral)
- `src/ir/coalesce/pass.zig` (8b.1 scaffolding)
- `src/engine/codegen/shared/regalloc.zig` (8b.2-c LIFO
  free-pool refactor)
- Lessons: `2026-05-09-greedy-local-already-does-reuse.md`

After 8b.2: 8b.3 (AOT skeleton), 8b.4 (≥10% aggregate
exit; absorbs 8b.1 + 8b.2 + 8b.3 contributions), 8b.5
(Phase 8 boundary audit), 8b.6 (open §9.9).

## Coalescer scaffolding (8b.1 [x] artefacts — for Phase 15 reference)

Surface preserved for Phase 15 detection lift:

- `src/ir/coalesce/pass.zig` — pass module + `run` shape +
  `isCoalesceCandidate` (MVP catalogue: `local.tee` /
  `local.get` / `local.set` / `select`) + `deinitArtifacts`.
- `src/ir/zir.zig` — `CoalesceRecord` + `func.coalesced_movs`
  slot.
- `src/engine/codegen/shared/compile.zig` — pipeline
  placement between regalloc and emit.
- `private/notes/p8-8b1-coalescer-survey.md` — Step 0
  survey across cranelift / wasmtime / regalloc2 / wasm3 /
  v1 zwasm (gitignored).
- ADR-0035 (post-regalloc slot-aliasing design) + ADR-0036
  (scope downgrade rationale).

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-054** (`blocked-by: separate investigation`) — OrbStack-
  only; independent of D-053. Likely Rosetta JIT-emulation
  interaction or Linux-x86_64-only path.
- **D-055** (`blocked-by: D-052 + emit_test_*.zig migration`) —
  x86_64 prologue inject deferred (sentinel ARM64-only).
- 9 `blocked-by:` rows — D-007 / D-010 / D-016 / D-018 / D-020
  / D-021 / D-022 / D-026 / D-028 / D-052; barriers all hold.

D-053 closed at `2e0022c` (was promoted to ROADMAP row §9.8a /
8a.5).

**Phase**: Phase 8 (JIT optimisation foundation 🔒、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
