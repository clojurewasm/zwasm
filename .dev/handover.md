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

## Current state — Phase 9 / §9.9/9.5-c-vi [x] (int lane access B/H/D); **§9.9/9.5-c-vii NEXT**

§9.9/9.5-c-vi adds 8 NEON lane-access encoders (UMOV/SMOV W
from B + INS B from W; UMOV/SMOV W from H + INS H from W;
UMOV X from D + INS D from X) plus 8 op_simd handlers wired
through two new shared helpers (`emitV128ExtractLane` /
`emitV128ReplaceLane`) that take an encoder thunk + lane mask.
This consolidates the per-shape boilerplate; each ZirOp arm
reduces to a one-line shape adapter.

i32x4 lane access already in 9.5-c-iii. f32x4/f64x2 lane
access + i64x2.mul synthesis defer to 9.5-c-vii (the D-form
encoders landed here will be reused by that synthesis).

Per LOOP.md chunk granularity, 9.5 row sub-split:
- 9.5-a/b/c-i…c-vi [x]: encoder foundation + shape-tag
  pipeline + Q-form spill + op_simd refactor + i32x4 lane
  access + ADD/SUB + MUL (16B/8H/4S) + int lane access B/H/D.
- 9.5-c-vii NEXT: i64x2.mul synthesis (extract / scalar-mul /
  insert sequence) + remaining lane-access shapes for
  f32x4 / f64x2 (FMOV / DUP / INS S/D variants).

Mac gates: zone ✓, file_size ✓, spill ✓, lint ✓; spec
212/0/20, wast 1158/0/0.

**§9.9/9.5-c-vii NEXT** — i64x2.mul multi-instr synthesis +
extract/replace_lane for f32x4 / f64x2. Synthesis sequence
for i64x2.mul: extract each i64 lane via the new
`encUmovXFromD`; scalar MUL via inst.encMulRR; insert via
the new `encInsDFromX`. f32x4 / f64x2 lane handlers reuse
`emitV128ExtractLane` / `emitV128ReplaceLane` (introduced
this chunk) once FMOV/DUP/INS S/D encoders land.

## Active task — §9.9/9.5-c-vii: i64x2.mul synthesis + f32x4/f64x2 lane access **NEXT**

Two independent groups, both in `op_simd.zig`:

1. **i64x2.mul** (no NEON 2D-MUL exists). Synthesis sequence per
   lane: `encUmovXFromD` (extract i64) → scalar `encMul` (X-form,
   reuse from `inst.zig`) → `encInsDFromX` (insert back). Need a
   dedicated handler since `emitV128Binop` assumes a single
   3-operand NEON encoder.
2. **f32x4 / f64x2 extract_lane / replace_lane** (4 ops). Reuse
   `emitV128ExtractLane` / `emitV128ReplaceLane` introduced this
   chunk after adding FMOV-S / FMOV-D + INS-element-from-element
   encoders in `inst_neon.zig` (or DUP-derived alternatives).
   FP-register destination requires a different `resolve*` /
   spill path than the GPR-result int-lane handlers; structurally
   distinct enough to live alongside the helpers as a sibling
   pair (`emitV128ExtractLaneFp` / `emitV128ReplaceLaneFp`).

After 9.5-c-vii: 9.6 ARM64 NEON emit pt 2 (float arith +
compare + shuffle + conversion) → 9.7/9.8 x86_64 SSE4.1 emit
→ 9.9 spec test → 9.10 bench → 9.11 audit → 9.12 open §9.10.

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
