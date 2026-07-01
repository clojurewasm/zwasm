# Structural rework campaign — correctness-assured redesign

> **RETIRED CAMPAIGN MACHINERY (2026-07-01).** Loop-era procedure. The design
> priority it serves still holds, but in maintenance mode a rework lands as a
> normal `develop/<slug>` branch → PR → CI → merge, not an autonomous campaign.
> Any `zwasm-from-scratch` / direct-push references below are historical.

> Loaded on demand when a rework campaign is active (handover `## Active
> rework campaign`). Authored per ADR-0153. Sits ABOVE bundle mode +
> the `architectural` chunk type — a multi-bundle campaign with five
> ordered phases. The design priority it serves:
> `feedback_design_priority_completeness_over_v010` (memory) + ROADMAP
> §1.2 (parity) + §1.4 (lightweight-fast).

## When a campaign triggers

A **measured** structural deficiency in a 完成形 dimension — clean
design / full-featured / 100% spec / **lightweight-yet-fast** — that a
quick local fix cannot close. The canonical signal: a **v1-parity miss**
(§1.2) whose root cause is a deliberate v2 simplification (e.g. D-265:
the deterministic-slot regalloc is ~2.3× slower than v1 on loop-locals).

**Default posture (ADR-0153): schedule the rework, do NOT defer past
v0.1.0.** v0.1.0 timing never gates the decision; correctness + design
quality do. This is the opposite of the old "perf gap → debt-row →
maybe later" reflex.

**This is an AUTONOMOUS judgment, never a user gate.** Once a 完成形
deficiency is measured, the loop decides to open the campaign and runs
it to completion on its own — it does NOT stop to ask permission. The
project philosophy (this doc + the design priority + the inviolable
principles) IS the decision criterion: apply it and proceed (re-arm
every cycle). Stopping to ask "should I do this rework / is this phase
done?" is the over-babysitting anti-pattern. The only stop is a genuine
pre-existing bucket-2 (a proven ROADMAP §2 conflict), which is rare and
already handled by the stop-bucket framework — campaigns add NO new
user-stop.

**Campaign vs quick fix vs bundle:**
- **Quick fix** — local, single-layer, ≤ a few chunks, no ADR. Just a
  normal `emit`/`infrastructure` chunk. Not a campaign.
- **Bundle** — multi-cycle integration of an already-designed thing.
- **Campaign** — cross-layer redesign of a hot / correctness-critical
  path where the design itself is in question. Needs investigation +
  correctness-assurance + retrospective phases. THIS doc.

## Hard constraint — stay within the inviolable principles

P3 + P6 = single-pass (Decode → ZIR → regalloc → emit; **no SSA /
multi-pass IR optimisation**). §1.3 + §3.2 = a multi-tier optimising
JIT is **permanently post-v0.1.0**. A rework improves the **single-pass
baseline** (v1 is the existence proof — its locals-in-registers
allocator is also single-pass), never adds an optimisation tier. Staying
within P3/P6 IS the philosophy-aligned **autonomous** judgment — never
violate an inviolable principle. If an approach seems to need a P3/P6
violation, it is the wrong approach: find one within single-pass and
proceed. (Only a *genuinely-proven* impossibility is the pre-existing
bucket-2 stop = ROADMAP §2 conflict — the campaign adds no new gate.)

## The five phases (I + II are hard gates before any redesign code)

**"Hard gate" = a self-enforced ORDERING invariant, NOT a
user-intervention point.** The loop checks the gate itself (e.g. "is the
Phase-II correctness net green before I write Phase-IV redesign code?")
and proceeds autonomously — it never pauses for user approval at a phase
transition. The gate constrains the *order* of the loop's own work, not
who decides. Campaigns re-arm every cycle like all other loop work.

### I — Investigation (調査)

Deep, multi-angle. Not one Step-0 survey. Exit criteria (ALL):
- Root cause confirmed to a **mechanism** (read the source / dump the
  emit), not an inference. Use subagents for cross-codebase reads.
- ROI ceiling **measured** (commit/revert spikes per measure-first;
  v1 is often the existence proof of the achievable ceiling).
- Cross-layer **blast radius mapped** (which zones / files / both
  backends / which invariants).
- ≥2 candidate approaches with cost + risk + which inviolable
  principles each touches.
- **Output = a written findings doc** (template: `bench/results/
  s15p_parity_vs_v1.md`). Cited by Phase III's ADR.
Apply `investigation_discipline.md` (hypothesis list, dedup vs
debt/lessons) + `extended_challenge.md` Step 4 (裏取り: v1, reference
repos, spikes).

### II — Correctness assurance FIRST (正しさ担保) — HARD GATE (self-enforced; not a user stop)

Before ANY design code: pin the current correct behaviour of the area
being reworked so the rework **cannot silently regress**. Exit (ALL):
- Characterization tests covering the area's current behaviour
  (differential `interp == jit`, P12; and vs v1 where it is the oracle).
- **Adversarial** tests targeting the specific failure modes the new
  design risks (e.g. for a register-residency rework: a GcRef held only
  in a register at a collection point; a local read across a back-edge
  after a `local.set`; aliasing under pressure). This is where a
  D-261-class "no adversarial test" gap gets closed FIRST.
- The new tests are GREEN on the *current* design (they characterize,
  not yet drive) and live under `test/edge_cases/` per `test_discipline.md`.
These are **`test-only` chunks** — explicitly allowed before the design
ADR (the `architectural` "no code until ADR Proposed" rule governs
*redesign* code, not characterization tests of existing behaviour).
**You do not optimise an area you cannot prove you have not broken.**
Skipping or deferring Phase II is the forbidden anti-pattern (ADR-0153 §4).

### III — Design (設計)

An ADR for the new single-pass architecture. MUST name:
- The invariants that prevent regressing to the old bugs — cite the
  lessons (W54 / `regalloc-pool-scratch-overlap` / cohort pinning).
- The cross-layer touch-points + an **incremental, behaviour-preserving
  migration path** (small steps, net green throughout).
- The measurable exit (ROI recovery target + green test net + the
  Phase-II adversarial net).
Spike off-branch first (`private/spikes/`, `spike_discipline.md`) if the
approach is unproven. No `zwasm-from-scratch` code until the ADR is
Proposed (the `architectural` chunk rule).

### IV — Implementation (実装)

Behaviour-preserving TDD. **Full test net (incl. Phase-II adversarial)
green at EVERY commit** — correctness is non-negotiable; this is
*assured-correctness* optimisation, not "optimise then fix". Perf
measured at milestones; the ROI target is a gate, not a hope. Bundle
mode for continuity; the `architectural` 3-cycle cap forces a step-back
to spike if a sub-step drifts. 3-host gate per normal (ubuntu test-all
on emit changes — D-262 / cross-compile≠cross-run).

### V — Retrospective (振り返り)

At campaign close AND at major milestones:
- Did it hit the 完成形? (the measured target met + the design is
  clean, not a patch).
- What NEW risk / debt did the rework introduce? File it.
- Update debt + lessons; add a **Revision note** to the superseded
  simplification ADR (e.g. ADR-0149/0150 once register-resident locals
  land — their "~0 headroom" was wrong for this pattern).
- Re-derive: are there sibling sites with the same deficiency
  (`test_discipline.md` §2 grep-siblings, raised to the design level)?

## Handover wiring

A campaign carries a `## Active rework campaign` section in handover.md
(Resume Step 1c detects it, supersedes ROADMAP lookup — parallel to the
bundle override 1b):

```markdown
## Active rework campaign
- **Campaign-ID**: regalloc-resident-locals (D-265)
- **Phase**: II — correctness assurance  (of I→V)
- **Findings-doc**: bench/results/s15p_parity_vs_v1.md
- **ROI target**: w45_addi 2.3× → ≤1.1× vs v1; full test net green
- **Correctness net**: <the adversarial tests Phase II must add>
- **Next**: <the single next concrete step in the current phase>
```

Bundle mode (`## Active bundle`) is used WITHIN a campaign phase for
per-multi-cycle continuity; the campaign section is the outer frame.

**Opening a campaign from an existing bundle**: when an investigation
bundle (e.g. `15.P-parity-vs-v1`) surfaces a structural deficiency that
warrants a campaign, the bundle's work becomes Phase I evidence —
**close/subsume that bundle** (its findings doc + debt are the Phase I
output), then open the `## Active rework campaign` section starting at
the phase that work has already reached (often Phase II).

Campaign close = Phase V done + the ROI + test-net exit met; remove the
section, ROADMAP/debt updated, ADR Revision notes landed.

## Why this exists

Large reworks of hot, correctness-critical paths are where LLM-driven
work is most prone to two opposite failures: (a) never starting (defer
to debt forever — the D-265 reflex), or (b) starting the redesign code
before the correctness net exists (silent miscompile — the D-260/D-245
class). The campaign makes investigation + correctness-first + retrospect
*mandatory ordered gates*, so the rework is both **done** (not deferred)
and **safe** (not rushed). Pairs with the design priority: 完成形 over
v0.1.0 speed, but never over correctness.
