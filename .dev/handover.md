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

## Current state — Phase 9 / §9.6/9.6-g-iii [x] (i→f convert × 4); §9.6/9.6-f-ii deferred via D-056; **§9.6/9.6-g-iv NEXT**

§9.6/9.6-g-iii adds 4 NEON SCVTF/UCVTF .4S/.2D encoders + 4
op_simd handlers + new `emitV128ConvertLowI32ToF64` helper for
the f64x2.convert_low_* synthesis (SXTL/UXTL .2D + SCVTF/UCVTF .2D
in place). Cranelift cross-checks for both .4S and .2D forms
verified. FPCR RMode=00 default matches Wasm spec round-to-nearest-
even.

Per LOOP.md chunk granularity, §9.6 sub-row state:
- 9.6-a/b/c-i/c-ii/d/e/f-i/g-i/g-ii/g-iii [x]: FP arith / compares /
  int compares / swizzle / extend / narrow / i→f convert.
- 9.6-f-ii deferred (D-056): shuffle + v128.const need const-pool
  ADR; trigger = §9.6 close v1-audit findings.
- 9.6-g-iv NEXT: promote/demote (FCVTL/FCVTN — width-changing FP).
- 9.6-g-v: trunc_sat with NaN→0 + clamp (most complex; FCVTZS/U
  + special-value handling).

Mac gates: zone ✓, file_size ✓, spill ✓, lint ✓; spec
212/0/20, wast 1158/0/0.

**At §9.6 close (queued)** — fire a broad pre-9.7 v1+OSS audit
before flipping §9.6 to `[x]`:
- Scope: v1's `src/jit_x86/`, `src/jit_arm64/`, `src/regalloc/`,
  `src/liveness/`, `src/hoist/`, plus wasmtime/cranelift, zware,
  wasm3 for SIMD-128 specifically (v1 has no SIMD). Compare to
  v2's full Phase 7 + Phase 8 + §9.5/9.6 surface — NOT just 9.6.
- Triage stance: **aggressive cleanup, not deferral**.
  - Mechanical & behaviour-preserving → fix inline in the audit's
    commit (e.g. `chore(p9): apply v1-audit findings batch`).
  - Structural / ADR-grade choice → file ADR per §18 + reference
    in handover; queue a follow-up §9.x row if non-trivial.
  - Blocked by external barrier → debt entry naming the barrier.
- Output: `private/notes/p7-9.6-v1-audit.md` (gitignored,
  200-400 lines, each finding tagged ✓/⚠/✗ + action taken).
- Exit signal: handover gets a `v1-audit done at <SHA>` line so
  later resumes don't re-fire. Subsequent unrelated commits are
  not audit findings.
- Motivation: §9.5/§9.6 ran with under-applied Step 0 discipline
  (re-derived NEON encodings from spec without consulting
  cranelift/zware/wasm3); Phase 7 likewise mostly re-derived
  x86_64 from Intel SDM. v1 worked out non-obvious details
  (scratch conventions, prologue/epilogue shape, trap stub
  plumbing, ABI quirks) — better to back-fill before x86_64 SIMD
  (§9.7) where the same gaps would compound.

**§9.6/9.6-g-iv NEXT** — FP promote/demote (2 ops):
- f32x4.demote_f64x2_zero → 2 f64 lanes → 4 f32 lanes (lower 2
  populated, upper 2 zero). NEON `FCVTN V<rd>.2S, V<rn>.2D` writes
  lower 64 bits, zeros upper. Single instruction.
- f64x2.promote_low_f32x4 → lower 2 f32 lanes → 2 f64 lanes.
  NEON `FCVTL V<rd>.2D, V<rn>.2S` (width-doubling FP convert).

NEON encoders: FCVTN/FCVTL (advanced SIMD two-reg misc, FP).
Per Arm IHI 0055 §C7.2.118 (FCVTN) / §C7.2.116 (FCVTL).

Step 0 should verify encoding bases + confirm FCVTN's upper-half
zeroing (since Wasm `demote_f64x2_zero` requires upper 2 lanes
to be 0). Estimated ~50 src + ~30 tests.

Estimated ~150 src + ~80 tests; may need a `private/spikes/`
spike to verify the const-pool / scratch-reg approach before
landing.

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
