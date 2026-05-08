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

## Current state — Phase 9 (SIMD-128) / §9.9/9.2 [x] (ADR-0041); **§9.9/9.3 NEXT**

§9.9/9.2 ADR-0041 landed (`.dev/decisions/0041_simd_128_
design.md`, Status: Accepted). Design framing:
- **Shape-as-variant ZirOps**: 171 pre-declared cover ~415 spec
  ops via shape-suffix encoding (P6 + §A12).
- **FP-class register pool reuse**: v128 vregs occupy V0-V31 /
  XMM0-XMM15 alongside scalar f32/f64. Spill-stride
  disambiguated via separate `ShapeTag` axis (per
  `single_slot_dual_meaning.md`); conservative per-vreg-pays-
  its-stride packing (Phase 15 lift via ADR-0038 class-aware).
- **Feature-register pattern**: `feature/simd_128/register.zig`
  installs all 171 op handlers into the central dispatch table
  at startup (per ADR-0023 §4.5).
- **Spec-fidelity NEON**: explicit IEEE-754 trap-on-specials
  overriding NEON's silent-saturate default; Wasm spec § cited
  per handler.
- **SSE4.1 minimum**: PMULLD / PINSRB-W-D / PBLENDVB required;
  runtime CPUID check at startup refuses pre-Nehalem hardware.

**§9.9/9.3 NEXT** — Validator extension: v128 type-stack +
per-op signatures via dispatch-table install (~150 src + ~80
tests). Activates the `feature/simd_128/register.zig` slot.

## Active task — §9.9/9.3: SIMD-128 validator extension **NEXT**

Per ADR-0041 §"Concrete chunk plan" + §"Decision" / 3:
v128 type-stack + per-op signatures via dispatch-table
install. Activates `src/feature/simd_128/register.zig` from
placeholder to load-bearing.

Smallest red test: validator accepts a wasm module with
`(func (result v128) (v128.const i32x4 0 0 0 0))` and
rejects type mismatches (e.g. `(i32.add v128.const)` should
TypeError). Existing `src/validate/validator.zig` consumes
type signatures from the dispatch table; SIMD ops register
their `(params, results)` shapes via the
`feature/simd_128/register.zig:register()` entry point
which gets called at startup.

Estimated diff: ~150 src + ~80 tests. Single chunk per
ADR-0041's chunk-plan row.

After 9.3: 9.4 IR (ZirOp activation + lower paths +
`Allocation.shapeTag()` API) → 9.5/9.6 ARM64 NEON emit →
9.7/9.8 x86_64 SSE4.1 emit → 9.9 spec test → 9.10 bench →
9.11 audit → 9.12 open §9.10.

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
