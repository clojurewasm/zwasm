# 0118 — Consolidate /continue loop scaffolding: rule taxonomy, skill split, mechanization, bundle mode

- **Status**: Accepted
- **Date**: 2026-05-26
- **Author**: claude (autonomous /continue prep path; user-delegated scope per 2026-05-26 collab)
- **Tags**: meta, scaffolding, /continue, rules, skills, context-budget, claude-code-best-practice
- **Paired ROADMAP row**: none (meta-ADR; touches `.claude/` + `.dev/handover.md` + `CLAUDE.md` only)

## Context

By 2026-05-26 the `.claude/` scaffolding had reached:

- **29 rule files** (3,616 LOC) — 14 auto-load on every `src/**/*.zig` edit.
- **5 skills** — `continue/SKILL.md` at 1,060 LOC (2.1× over the 500-LOC Claude
  Code recommendation) + `LOOP.md` at 673 LOC (1.3× over).
- **handover.md** at 185 lines (well over its own ≤100-line cap).
- Approx **12-15 K tokens of recurring overhead** at every `/continue` resume
  before any work begins.

The growth pattern is post-hoc: each failure mode (atom-rhythm 13-cycle
chain `e62db476`, 12-cycle D-153 on-branch spike, 50+ null-op heartbeat
2026-05-22, etc.) surfaced **one new rule** to defend against the
specific instance, but the same shape recurs in different guise. Phase 15
projections put rule count at **37-45** if the pattern continues — i.e.
linear with phase count.

Anthropic's 2026-05 official guidance (`code.claude.com/docs`) and
community evidence (`anthropics/claude-code#29971` context-rot issue)
confirm: **context bloat degrades LLM performance**. Skills should stay
≤500 LOC; rules belong in `CLAUDE.md` only when they are universal
conventions; **mechanizable checks should be scripts, not rule prose**.

The IT-1+IT-2 bundle stall in 2026-05-26 (lesson `e62db476`) made this
load-bearing: post-compaction sessions had insufficient effective budget
for multi-cycle integration because rule auto-load + hook re-injection
consumed it.

## Decision

Execute a **single-bundle meta-restructure** of `.claude/` + `CLAUDE.md`
+ `handover.md` per the following 6 axes. Bundle is self-applying — the
work itself demonstrates the `## Active bundle` continuity pattern it
introduces.

### D1. Retire 5 rules (zero-risk; self-flagged)

| File | Why retire |
|---|---|
| `.claude/rules/debug_jit.md` | 11-line stub; `debug_jit_auto` skill superseded |
| `.claude/rules/markdown_format.md` | Fully covered by `check_md_tables.sh` (PreToolUse hook) + `md-table-align` |
| `.claude/rules/runtime_instance_layer.md` | Pure re-projection of zone_deps + comment_as_invariant + no_fallback_on_failure for one dir |
| `.claude/rules/incremental_substrate_migration.md` | §9.12-B done; rule's own Status line declares completion |
| `.claude/rules/phase9_close_invariants.md` | Phase 9 = DONE 2026-05-24; rule's "Retirement status" line declares informational-only. Keep `check_phase9_close_invariants.sh` as permanent regression check |

### D2. Demote 3 rules to ≤15-line pointer stubs (mechanized)

| File | Mechanization |
|---|---|
| `comment_as_invariant.md` | `scripts/check_invariant_comments.sh` + ADR-0072 |
| `libc_boundary.md` | `scripts/check_libc_boundary.sh` + ADR-0070 |
| `doc_state_marker.md` | New `scripts/check_doc_state.sh` (grep `.dev/*.md` Doc-state markers) |

Stub content: 1-line rule statement + script invocation + ADR pointer.
Bodies stay accessible in git history.

### D3. Merge 5 overlap clusters into consolidated rules

| Cluster | Result | LOC saved (approx) |
|---|---|---|
| `architectural_spike` + `spike_lifecycle` + `extended_challenge §4` (spike portion) | `spike_discipline.md` | 200 |
| `no_fallback_on_failure` → `no_workaround` | (single file) | 70 |
| `handover_framing` + `no_handover_predictions` | `handover_doc_discipline.md` | 90 |
| `hypothesis_enumeration` + `heisenbug_discharge` | `investigation_discipline.md` | 80 |
| `edge_case_testing` + `bug_fix_survey` | `test_discipline.md` | 100 |

`extended_challenge.md` retains Steps 1-3 + Step 5 (permanent diagnostic
infra); Step 4 (spike option) moves to `spike_discipline.md`.

### D4. Split `continue/SKILL.md` per progressive disclosure

`continue/SKILL.md` (1,060 → ≤500 LOC target):

- Body retains: pickup procedure outline, stop-condition whitelist,
  push policy summary.
- Extract to siblings (loaded by procedure step only):
  - `continue/RESUME.md` — Step 0.4 / 0.5 / 0.5b / 0.6 / 0.7 detailed walkthroughs.
  - `continue/STOP_BUCKETS.md` — bucket 1/2/3 + autonomous-prep-paths catalog.
  - `continue/GATE.md` — 2-host parallel test gate shape.
- `LOOP.md` (673 → ≤400 LOC): trim retrospective narrative; move
  rationale prose to `.dev/lessons/`.
- Retrospective prose ("Why this step exists" / "2026-05-22 retrospective…")
  moves OUT of SKILL.md INTO the cited lesson files.

### D5. CLAUDE.md slim + frozen/dynamic hook split

CLAUDE.md (193 → ≤140 lines):

- Retain: identity, branch policy, 3-host gate summary, key references.
- Move out: detailed working agreement bullets (already partially
  pointer-only; finalize).
- New section: **Frozen reminders** (language policy, /continue
  literal=60, ROADMAP §18) — read once per session boundary.

`scripts/hooks/print_handover_brief.sh` (SessionStart + PostCompact):

- Remove: frozen reminder echo (now in CLAUDE.md, read on cold-start).
- Retain: handover.md + `git log -3` + ubuntu verdict.

### D6. Bundle-mode state machine

`.dev/handover.md` template gains optional `## Active bundle` section:

```markdown
## Active bundle (optional)

- **Bundle-ID**: `<range>` (e.g. `10.E-codegen-IT-1..IT-3`)
- **Cycles-remaining**: `<N>` (planning estimate, NOT prediction)
- **Continuity-memo**: `<observables to watch>` (1 line)
- **Exit-condition**: `<concrete measurable delta>` (e.g. "HandlerEntry count > 0 in unit test")
```

`continue/SKILL.md` Step 1: if `Active bundle` non-empty → bundle-next-step
takes precedence over ROADMAP §9 lookup (parallel to `Step 1a` close-plan
override).

Bundle exit gate (`scripts/check_bundle_active.sh --close`): the close
commit MUST land with the named observable delta verified. If delta = 0
after the planned N cycles, bundle either continues (add to N) or pivots
(handover rewrite + commit chore).

This is the structural defense against atom-rhythm (lesson `e62db476`).

## Alternatives considered

### A. Continue adding per-failure rules (status quo)

Project rule count grows ~+2 / phase → ~37-45 by Phase 15. Context
overhead grows linearly. Each new rule patches one instance, but the
shape recurs and forces another rule. **Rejected**: trajectory is
unsustainable; LLM context-rot becomes the dominant failure mode by
Phase 12+.

### B. Wholesale rewrite of `.claude/`

Discard the existing 29 rules + 5 skills + 4 hooks and re-author from
scratch following 2026 best practices. **Rejected**: high regression
risk (each rule encodes a past failure mode; full rewrite loses tacit
knowledge); bundle-mode is the only genuinely new piece — the rest is
consolidation, not redesign.

### C. Mechanization-only (no merges, no skill split)

Convert every mechanizable rule to a script but keep all 29 rule files.
**Rejected**: leaves the merge wins on the table; doesn't address the
1,060-LOC `continue/SKILL.md` over-budget shape; doesn't establish
bundle-mode.

### D. Skill split only (defer rule consolidation)

Split `continue/` first; defer rule cleanup to Phase 11. **Rejected**:
rule auto-load + skill body are additive context costs; both must drop
together for the per-resume budget to meaningfully shrink.

## Consequences

### Positive

- **Auto-load context overhead drops ~47%** on the `src/**/*.zig` hot
  path (1,800 LOC → ~950 LOC per typical resume).
- **`continue/` skill returns to ≤500-LOC budget** per Anthropic
  recommendation; progressive disclosure restores intended pattern.
- **Bundle-mode** lets multi-cycle integration work (IT-1+IT-2+IT-3,
  GC heap impl, regalloc3 refactor, threads proposal) survive session
  boundaries without atom-rhythm drift.
- **Mechanization** removes rule prose for checks scripts already
  perform — scripts run at gate time at zero LLM token cost.
- **Phase 11..15 rule fan-out** flattens: new failure modes default to
  script + lesson, not new rule.

### Negative

- **Rule path-coverage map changes** — historical commit refs that cited
  `architectural_spike.md` etc. resolve to the merged file. Lineage
  preserved via git log; the merge commit includes a "absorbs" table.
- **Bundle-mode requires discipline** — without an honest
  `Exit-condition` it degenerates to the same atom-rhythm. The script
  gate (`check_bundle_active.sh --close`) enforces delta ≥ 1.
- **Skill split increases file count** in `continue/` from 2 to ~5.
  Net body LOC drops; navigation cost slightly rises.

### Neutral / follow-ups

- `audit_scaffolding` skill needs an update pass to reference the new
  rule names (mechanical rename; included in this bundle).
- Existing ADRs / lessons that cite retired rules need
  rename-or-strike. Done in this bundle's Phase 7 verification.
- New rules introduced beyond this point default to **lesson first;
  promote to rule only on 3+ citations** per `lessons_vs_adr.md`. This
  was already the policy but the retire/merge pass re-anchors the
  threshold.

## Removal condition

This ADR retires when:

1. All 6 axes (D1-D6) implemented + auditing passes.
2. Phase 15 close (= v0.2.0 ship) confirms no
   bundle-mode-mediated atom-rhythm regression.

Status will transition to `Closed (Implemented)` with the impl
SHA range cited at v0.2.0 ship gate.

## References

- **Survey reports (this resume, 4 parallel agents)**:
  - skill-creator + 2026 best practices (Claude Code official docs).
  - Project priorities + code surface (123K LOC src/, 11K test/,
    53K .dev/, 8.3K .claude/).
  - Rule deep dependency + overlap analysis (29→12-16 logical).
  - Skill ecosystem audit (`continue/SKILL.md` 2.1× over 500 cap).
- **Lessons**:
  - `.dev/lessons/2026-05-26-eh-codegen-foundation-atom-rhythm.md`
    (`e62db476`) — the atom-rhythm pattern this ADR's D6 defends.
- **External**:
  - https://code.claude.com/docs/en/skills (≤500 LOC recommendation)
  - https://code.claude.com/docs/en/sub-agents (`context: fork`)
  - https://github.com/anthropics/claude-code/issues/29971 (context rot)
  - https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices
- **Related ADRs**:
  - ADR-0076 (autonomous push; D2 single-push commit pair — preserved).
  - ADR-0099 (file-size smell — applies to rule files too).
  - ADR-0104 (Phase 9 honest-accounting — set the audit precedent
    this ADR generalizes).
  - ADR-0072 (invariant-as-comment — survives via demoted stub).
  - ADR-0070 (libc dependency policy — survives via demoted stub).

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-26 | `0b0a514d` | Initial accepted version (autonomous user-delegated scope; D1-D6 all in this bundle). |
| 2026-05-28 | `a830a95f` | D7 amendment: yield-aware pacing soft-surface (LOOP.md "Yield-aware pacing" section + lesson `2026-05-28-yield-taper-pacing.md`) + bundle-vs-debt-row clarification (SKILL.md). Empirically observed in 2026-05-28 EH session: 8 consecutive low-yield chunks shipped after D-181→D-184 closes before user manually paused. New rule: at Step 1 (Plan), classify last 5 commits by yield-class (high: debt closed / ROADMAP `[x]` / behaviour delta / bundle close vs low: test-only / docs / refactor-no-delta); if ≥4 are low-yield AND next planned chunk is also low-yield, write a one-line `Yield-taper note` to handover's Open questions / blockers. NOT a stop — bucket 3 strict discipline unchanged. Lowers user's circuit-breaker friction by surfacing the pattern. Bundle vs debt distinction tightened: bundle = active multi-cycle work (next cycle picks it up); debt row = filed-then-deferred gap. |
