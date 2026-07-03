# Maintenance-mode scaffolding necessity audit (2026-07-03)

> **Doc-state**: ACTIVE — report only (改変ゼロ). Drives the E-段2 edit batch.
> Supersedes nothing; complements `audit_scaffolding` (staleness) with a
> **necessity** lens under the post-v2.0.0 premise shift.

## Premise

The dev scaffolding was built by an **autonomous `/continue` build-campaign
loop**, now RETIRED (v2.0.0 shipped to `main`; maintenance mode = cut a
`develop/<slug>` branch → PR; CI's 3-OS `ci-required` gate runs on every PR).
Much scaffolding was campaign machinery (loop self-perpetuation) or an
AI-over-generation **smell detector** during rapid build. This audit judges
each piece's NECESSITY now, not just its staleness. Three read-only survey
agents covered: (A) loop machinery + working-doc discipline, (B) caps + gate
scripts, (C) auto-loaded rules + skills.

## The load-bearing structural finding (reframes everything)

**CI's `ci_gate.sh` runs only `zig fmt` + `test-all` (+ extended JIT/DCE/AOT).
It does NOT run `file_size_check` / `zone_check` / `spill_aware_check`.** Those
three fire ONLY in the local `gate_commit.sh`. So the caps and smell detectors
are purely a **local pre-commit affordance** — the authoritative `ci-required`
PR gate never sees them. Consequence: *relaxing a local check ≈ deleting it*
(there is no CI backstop). Two forks follow from this, both surfaced below.

## A. Autonomous, doc/config-only (E-段2 executes — cheap CI, no ADR)

| Item | Verdict | Action |
|---|---|---|
| `.dev/handover.md` | STALE + reshape | Rewrite to a plain maintenance **state doc**. Currently claims `v2.0.0-alpha.3` / Latest `v1.11.0` / "LOOP CLEAN-STOPPED bucket-3 / re-arm / wakeup" — all false post-v2.0.0. |
| `continue/SKILL.md`, `LOOP.md`, `RESUME.md` | SIMPLIFY | Strip retired loop mechanics (Steps 6-8 push/kick/`ScheduleWakeup(60)`, `zwasm-from-scratch` push, self-re-arm, "loop never voluntarily exits"). Keep resume + TDD + PR flow, chunk-type taxonomy, anti-patterns. |
| `continue/{LOOP,RESUME,STOP_BUCKETS}.md` | ARCHIVE | Move under an `archive/` marker (or `.dev/archive/`) so they stop reading as live procedure; keep as dated history. `STOP_BUCKETS.md` fully superseded by SKILL's 3-bucket summary. |
| `continue/{GATE,REWORK}.md` | KEEP | GATE = scope-adaptive pre-PR verification (banner→`ci-required`); REWORK = ADR-0153 rework procedure, still cited. |
| `handover_doc_discipline.md` (+ ref) | SIMPLIFY | Drop §1 "forbidden surrender phrase" grep + bucket-3 stop template (existed to stop the LOOP surrendering; no loop now). Keep §2 no-predictions, §6 length cap, fact-source table. |
| `rules/{extended_challenge,textbook_survey}.md` | SIMPLIFY | Invariant stays live (don't-paper-over-absence; Step-0 survey); deloop the "/continue stop bucket-2" / "the autonomous loop" framing. |
| `dispatch_consistency_audit/SKILL.md` | RE-SCOPE | Drop the dead "fires after §9.12-B completion" phase trigger (`b9a138f3` done); keep the periodic 3-way axis-match check (`dispatch_collector.zig` still live). |
| `meta_audit/SKILL.md` | RE-SCOPE | Drop the dead "Phase boundary" auto-trigger; retain as the user-gated skepticism audit. |
| `.claude/settings.local.json` | PRUNE | Remove the 3 allow entries targeting the retired `-zwasm-from-scratch/memory` working dir (dead grant: an `rm -rf` + 2 reads). |
| EXEMPT marker prose (instance.zig ~15-line changelog, validator.zig, …) | RELAX | Collapse each to one line (rationale + ADR ref); ADR-0099's revision history already holds the raise-log. Marker-only edits are sanctioned (memory `feedback_filesize_cap_relax_ok`). NOTE: touching a `.zig` file → heavy CI, so batch these with Batch B/C code PRs, not the doc PR. |
| debt.yaml header "Refresh on every /continue resume Step 0.5" | SIMPLIFY | Reword to "per-session / pre-PR". |

**All 21 auto-loaded rules KEEP** — lean ADR-0118 D2 stubs, path-gated on
`src/`/`build`/`.dev`, fire on any maintenance edit; none bloated, none
orphaned, none loop-only in substance. All 24 `references/*.md` KEEP.
`audit_scaffolding` + `debug_jit_auto` skills KEEP. `zone_check` /
`spill_aware_check` / `orphan_guard` / `gate_commit` KEEP (see §B caveat).

## B. NEEDS-ADR / user decision (do NOT auto-execute — frozen-invariant land)

These deviate ROADMAP §-protected areas or the CLAUDE.md **Frozen invariants**;
per §18.2 an ADR is filed first, and the gate-cadence change touches a frozen
invariant → user ratification, not autonomous.

1. **File-size cap POSTURE** (ADR-0099 D1/D4, ROADMAP §A2/§5). Recommendation:
   demote the 2000 hard-cap from a `--gate` BLOCK to a WARN (the
   smell-during-rapid-AI-generation premise is gone; pressure files are all
   irreducible catalogs/spec-walkers already investigated). Keep the soft-1000
   WARN as an advisory signal. → **amend ADR-0099**.
2. **Windows-BATCHED / `--suspend` cadence + `gate_merge.sh`** (ADR-0076 D8,
   ADR-0174; a CLAUDE.md Frozen invariant). Recommendation: since CI runs the
   Windows leg on **every PR**, local Windows gating is no longer load-bearing
   for merge safety — retire `should_gate_windows.sh`'s BATCHED/suspend
   heuristic, demote `gate_merge.sh` to an optional pre-PR pre-flight. →
   **amend ADR-0076 / ADR-0174**.
3. debt.yaml `status` legend (ADR-0129) + `front:` grouping (ADR-0186) — still
   fit maintenance; **no change** (listed so it's not mistaken for prunable).

## C. The relax-vs-promote fork (decide before touching §B.1/§B.2)

Because CI never runs `file_size_check`/`zone_check`/`spill_aware_check`,
"relax locally" and "delete" are nearly equivalent. If any of the three is
judged still load-bearing — **`zone_check`** (Zone 0–3 layering, a real
architectural guarantee not covered by tests) and **`spill_aware_check`** (a
bare `resolveGpr` on a spilled vreg → runtime `UnsupportedOp` miscompile) are
the candidates — the correctness-preserving move is to **add it to
`ci_gate.sh`** (promote to the authoritative gate) rather than relax it. This
is a genuine choice for the user:
- **Promote** zone_check + spill_aware_check into CI → they become real merge
  gates (slightly slower CI, but enforced for external contributors too).
- **Leave local-only** → accept they are author-discipline nudges that a
  contributor bypasses; then relaxing the caps is low-risk.

## Batching plan (CI-frugal)

- **E-段2a (doc-only PR)**: handover rewrite, continue-doc deloop+archive,
  handover_doc_discipline trim, extended_challenge/textbook_survey deloop,
  dispatch_consistency_audit + meta_audit re-scope, settings.local.json prune,
  debt.yaml header reword, this report. One doc-only PR → `ci-required` near-instant.
- **EXEMPT-marker prose collapse**: ride Batch B/C (they already touch `.zig`).
- **§B ADR items + §C fork**: surface to user; on ratification, one ADR PR
  (doc-only) then the script edits.

## Source

Read-only survey agents 2026-07-03 (A: loop docs, B: caps/scripts, C: rules/skills).
Anchors: ADR-0099 (caps), ADR-0076/0174 (gate cadence), ADR-0118 (rule stubs),
ADR-0129/0186 (debt schema), ADR-0153 (rework). Memory:
`feedback_filesize_cap_relax_ok`, `feedback_system_defenses_over_scripts`.
