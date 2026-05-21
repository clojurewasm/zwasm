# ADR-0080 Withdrawn — Step 0 survey overestimated emit.zig int/float carve

**Date**: 2026-05-21
**Keywords**: ADR-0080, emit.zig, per-op-file, ADR-0074, survey overestimate, dispatch arm, code already extracted, file split, architectural, withdraw
**Citing**: `2b8e2447` (ADR-0080 Withdraw amendment commit)

## What happened

Step 0 survey for ADR-0080 (emit.zig int/float source split)
proposed extracting `emit_float.zig` at ~350 LOC by moving
float-specific code out of `emit.zig` (1300 LOC). Same-day
implementation-prep verification — Reading the dispatch
switch + counting actual float-specific lines — surfaced
that the survey overestimated by an order of magnitude:

- `emit.zig` has 18 float-prefix dispatch arms (`.f32.*` /
  `.f64.*` cases), all **1-line routes** like
  `.@"f32.load" => try op_memory.emitF32Load(&ctx, &ins),`.
- The actual float-specific emit logic lives in
  `op_alu_float.zig`, `op_memory.zig`, `op_convert.zig`,
  `op_simd_float.zig` — extracted earlier per ADR-0074's
  per-op-file pattern.
- Carving emit_float.zig would produce a ~50-LOC wrapper
  file bundling those 18 routes; emit.zig would shrink by
  ~50 LOC (from 1300 to ~1250), nowhere near the 1300 → 400
  the ADR's Decision section claimed.

The split shape is wrong. ADR-0080 withdrawn same day.

## Root cause

Step 0 survey's brief asked for "structural inventory" but
didn't direct the subagent to **measure the line-count
distribution** of dispatch-arm bodies (1-line route vs
multi-line inline recipe). The subagent inventoried what
was conceptually float-related (= the 18 arms + param
marshalling + convert ops + return marshal) without
discriminating already-extracted-elsewhere routes from
inline-bodies.

Compounding factor: ADR-0079 (runner.zig split) precedent
created a mental template of "extract domain into new file
along semantic axis". That template applies cleanly to
runner.zig (3 conceptually distinct functions) but doesn't
apply to emit.zig (one big compile() function whose
dispatch arms ALREADY dispatched out to per-op-modules).
The survey inherited the template without re-validating
its applicability.

## Fix (or path forward)

Withdrawn ADR-0080. Successor ADR-0081 (next cycle) will
propose the **setup-pipeline split** along the actual
extractable mass:

- `emit.zig` (driver, ~800 LOC): `compile()` entry,
  dispatch switch, control-flow scaffold, dead_code
  tracking, SIMD inline cases.
- `emit_setup.zig` (new, ~500 LOC): `computeOutgoingMaxBytes`,
  `computeLocalLayout`, `localDisp`, prologue assembly,
  parameter marshalling (int + float interleaved), local
  zero-init, state init (EmitCtx assembly).

This is a 2-way split along pipeline-phase axis (ADR-0079
Alt B shape), not a 3-way domain axis. Honest about what's
genuinely extractable. emit.zig drops to ~800 LOC — still
over soft cap but better proportioned; future bumps land
in setup or driver based on which axis adds LOC.

**D-055 and D-081 re-evaluation**:
- **D-055** (sentinel wire-up + test migration) is
  **unaffected** — the discharge plan (`prologue.body_start_offset()`-
  relative migration + `inst.encMovMemDisp32Imm32` call wire)
  doesn't depend on the int/float source split. Stays
  `Status: now`.
- **D-081** (test rename to `<source>_test.zig` convention)
  needs barrier re-walk. Without `emit_int.zig` / `emit_float.zig`
  sources existing, the rename to `emit_int_test.zig` /
  `emit_float_test.zig` implies non-existent sources —
  violates ADR-0054 §"Naming convention". Path forward:
  (a) ADR-0054 amendment allowing domain-grouped tests of
  monolithic source, OR (b) drop the test files entirely
  and re-bin tests into `emit_test.zig` (single file) + new
  per-op `_test.zig` files alongside each `op_*.zig` source.
  Decision deferred to ADR-0081 cycle.

## Why this didn't surface earlier

The survey shape is the canonical Step 0 brief (see
[`textbook_survey.md`](../../.claude/rules/textbook_survey.md)).
It directs the subagent to describe **design space**, not
to **measure extraction cost**. For ADR-grade architectural
chunks, the bias toward "name design alternatives" produces
plausible-sounding splits that aren't pre-validated against
the actual file structure.

The fix for future cycles: when Step 0 survey targets a
**refactor / extraction** (vs a new feature), the brief
should explicitly direct the subagent to (a) count
1-line dispatch routes vs multi-line inline recipes,
(b) attribute each domain-classified line to either
"already extracted to <other file>" or "still inline",
and (c) report the actual carve LOC delta per proposed
split shape.

## Related

- ADR-0080 — Withdrawn 2026-05-21 (this lesson's subject).
- ADR-0079 — runner.zig 3-way split (the precedent that
  shaped the wrong template).
- ADR-0074 — per-op-file Zone split (the absorption
  pattern that ADR-0080's survey didn't account for).
- D-055 / D-081 — debt rows whose discharge path
  re-walks per this lesson.
- `.claude/rules/textbook_survey.md` — Step 0 survey
  discipline; candidate for amendment ("when refactoring,
  measure extraction cost").
- `.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md`
  — sibling class: narrative diverged from landed state.
  This lesson's class: **survey** diverged from landed
  state at design time.
