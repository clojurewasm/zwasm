---
name: file-size hard-cap acknowledgment vs enforcement gap
description: §14 file-size hard-cap is enforced at commit-time but not at gate boundaries; "acknowledged + tracked debt" still equals "active violation"
type: lesson
---

# 2026-05-08 — file-size hard-cap blind spot

> Citing: meta_audit 2026-05-08 phase7-close (`<backfill>`).
> Sibling: D-051 (x86_64/emit.zig prologue extraction).

## What surfaced

At Phase 7 close, three source files were over the §A2 hard cap
(2000 LOC):

- `src/engine/codegen/x86_64/emit.zig` — 4305 LOC
- `src/engine/codegen/x86_64/inst.zig` — 2530 LOC (split this gate)
- `src/engine/codegen/arm64/emit_test.zig` — 2356 LOC (split this gate)

emit.zig had been 3989 LOC at the §9.7 / 7.5d sub-b 9-module split
landing (D-030 discharge, 2026-05-07); subsequent 7.7 + 7.9 + 7.10
chunks regrew it by ~1500 LOC over 2 days without any pause.

Each commit individually passed `bash scripts/file_size_check.sh`
because the script is wired into `.githooks/pre_commit`, which
fmt/file_size/lint guard isn't firing per a snake_case mismatch
(documented in handover.md "Pre-existing infra"). Even when it
does fire on Mac post-commit, the commit had already landed.

## The actual blind spot

The `/continue` per-task TDD loop's Step 5 test gate verifies
**correctness** (tests green); the §14 forbidden-list line "Single
file > 2000 lines" is NOT one of the things the per-commit gate
re-checks visibly. Each commit's diff incrementally added ~50-200
LOC to emit.zig — none of those individual deltas tripped a
visible alarm. The hard cap was crossed silently.

Even when the cap was crossed and a debt entry (D-030 follow-up)
acknowledged the violation, **the violation continued to exist
for the rest of Phase 7**. The /continue loop interprets
"acknowledged + tracked" as "fine to continue", which inverts §14's
meaning ("Single file > 2000 lines" reads as forbidden, not as
"deferrable when annotated"). The phase-boundary `audit_scaffolding`
fired at 7.12 and flagged the violations as `watch`-grade — one
priority level lower than the §14 line warrants.

## What should change

This is a `/continue` LOOP / `audit_scaffolding` CHECKS gap, not
a §14 amendment:

1. **Per-task Step 5 gate**: when the file-size check exceeds the
   hard cap on any source file the commit touches, surface it
   immediately and require either (a) splitting in this same
   commit, OR (b) an ADR-grade debt entry (not a passing
   reference) before the commit lands. The current acknowledgment
   path (debt entry buried in `.dev/debt.md`) is too quiet.
2. **Phase-boundary audit_scaffolding**: file-size hard-cap
   violations escalate from `watch` to `block` at every phase
   close, not just suggest. A `block` finding requires
   discharge or explicit ADR-tracked deferral with concrete
   gating condition.
3. **Gate document § file-size box**: a hard-cap violation cannot
   be ☑'d by the autonomous loop — only by the user
   collaboratively, with an explicit disposition statement.

## Why this is a lesson, not an ADR

The §14 line itself is correct (no rule change). What's wrong is
the **enforcement cadence**. Adjusting the audit + loop gates is a
process refinement, not a load-bearing design decision. ADR is
overkill; this lesson lives in `INDEX.md` for the next maintainer
who edits CHECKS.md or LOOP.md.

## Cross-references

- ROADMAP §14 (forbidden-list "Single file > 2000 lines (hard cap A2)")
- `.dev/lessons/2026-05-04-emit-monolith-cost.md` (the original
  pre-split observation; this lesson is its successor)
- D-030 (discharged 2026-05-07; emit.zig 8-chunk split)
- D-051 (Phase 8 prologue extraction; new this resume)
- `.dev/archive/phase_gates/phase8_transition_gate.md` §3 file-size box (archived 2026-05-19 in §9.12-A)
