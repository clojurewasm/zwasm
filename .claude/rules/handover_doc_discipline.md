---
description: "Handover.md discipline — drive next chunk, don't deliberate; no numeric predictions; forbidden surrender phrases grep-enforced. Absorbs former handover_framing.md + no_handover_predictions.md per ADR-0118 D3."
paths:
  - ".dev/handover.md"
  - ".dev/debt.md"
  - ".dev/ROADMAP.md"
---

# Handover doc discipline

`.dev/handover.md` is a **driving document**, not a **deliberation
document**. Every entry either:

1. Names a concrete autonomous next chunk (per LOOP.md chunk types:
   `emit` / `infrastructure` / `survey` / `architectural` /
   `test-only`), OR
2. Names a specific code/test/spec dependency provably waiting on
   external input.

Anything else is forbidden framing.

## §1 — Forbidden surrender phrases (grep-enforced)

`/continue` Step 1 runs:

```sh
grep -nE "user-judgment territory|wait for natural trigger|wait for .* fixtures|needs commitment to|substantial multi-cycle|deep .* work or wait|pivot to .* OR" .dev/handover.md
```

If non-empty → **the first chunk of the resume is the handover
rewrite itself**, not the prose-suggested chunk. The framing is
unreliable by construction.

| Phrase | Why forbidden | Replace with |
|---|---|---|
| `user-judgment territory` | Treats pickup as stop signal | Concrete chunk description |
| `Next pickup (user-judgment)` | Same | `Active task — <chunk-id>` |
| `wait for natural trigger` | Passive surrender; null-op recipe | Drop the option OR debt row `Status: blocked-by: <named event>` |
| `wait for ... fixtures` | Same | Same |
| `needs commitment to` | Frames work as requiring user buy-in | Just describe the chunk |
| `substantial multi-cycle ... work` | Cycle count is not a defer reason | Drop the adjective |
| `deep <X> work or wait` | Re-introduces wait option | Drop `or wait`; describe chunk |
| `pivot to <X> OR <Y>` | Implies user picks branch | Pick branch in handover; loop executes |

**Single allowed `user-judgment` use**: §18 ADR amendment requiring
user-flip at ADR-flip time. Even then, the draft is autonomous.

## §2 — No numeric predictions (future-tense)

Don't write speculative numbers in mutable docs:

- ❌ "Targets ~16 fails"
- ❌ "Expected to flip ~25 PASS"
- ❌ "Should reduce OrbStack from 79 to ~54"
- ✅ "Candidate: D-071 part (b) — i8x16.popcnt PSHUFB recipe"
- ✅ "Latest landed: 67aa0025 (see commit body for delta)"

### Where each fact-kind lives (single source of truth)

| Fact kind | Source of truth | MUST NOT duplicate in |
|---|---|---|
| Past chunk outcome (3-host gate, deltas) | commit message body (`git show <sha>`) | handover Current/Active state, debt narrative |
| Current FAIL counts / breakdown | `bash scripts/p<N>_*_status.sh` (live) | handover, debt |
| `now` debt rows | `.dev/debt.md` Status column | handover (point at, don't copy) |
| ROADMAP §9.<N> chunk records (immutable) | row at chunk-close time | handover |
| Hypothesis with TTL | debt row body, prefixed `Hypothesis (verified at <SHA-or-date>): ...` | handover |

`/continue` Step 0.5b runs `p<N>_*_status.sh` BEFORE believing
handover narrative; live script wins on disagreement.

### "Next candidates" correct shape (names + Refs only)

```markdown
## Next sub-chunk candidates (names only, NO predictions)

- D-071 (b) — i8x16.popcnt PSHUFB recipe
- D-071 (a) — i64x2.mul PMULUDQ recipe
- D-067 — bitmask validator-shape (lower + ARM64 emit)
```

### What §2 does NOT cover

Past-tense observations are facts, not predictions:

- ROADMAP §9.<N> chunk records ("9.9-g-12: Mac 11263/4, OrbStack 79
  fails") — immutable historical snapshot, stays.
- Commit message bodies — same.
- bench/ historical results — measured-at-commit-time, stays.

Trigger is **future-tense numeric claims about as-yet-unwritten
code**, not past-tense observations.

## §3 — Anti-pattern: 3-option pickup

The 2026-05-22 incident had handover present:

> (a) §9.13-0 windowsmini reconcile — substantial multi-cycle Win64 work
> (b) §18 amendment of §9.12-F exit criterion
> (c) Wait for natural trigger events

All three wrong: (a) provides an excuse not to do it, (b) is legit
user-judgment but the ADR draft is autonomous, (c) is "do nothing"
with justification.

**Replacement**: pick (a) and (b) as parallel autonomous tracks; drop (c).

## §4 — Bucket-3 stop framing (legitimate "wait for user")

The forbidden phrases above target the surrender failure mode. The
opposite shape — every autonomous lever pulled, remaining work
structurally needs user — is a **legitimate bucket-3 stop**:

```markdown
## Bucket-3 stop — user touchpoint required

All autonomous prep walked; loop stops without re-arm.

**Gating user touchpoint(s)**:
- ADR-NNNN — `Status: Proposed → Accepted` flip. After flip,
  autonomous loop resumes at <chunk-id>.

**Autonomous prep walked this resume** (do not re-walk):
- ADR-NNNN References enriched: <commit-sha> cites <source>.
- ADR-NNNN spike: `private/spikes/<slug>/` Status: <rejected|merged>.

**To resume**: flip the named ADR(s) and re-invoke /continue.
```

## §5 — What handover is NOT for

- Listing multiple "options" — the loop already picks by reading
  handover.
- Editorial framing on work difficulty.
- Cycle-count estimates (per §2).
- "I don't know what to do" — bucket-2 stop; `Open questions /
  blockers` with named investigation Step 1-3 attempt per
  [`extended_challenge.md`](extended_challenge.md).

## §6 — Length: soft/hard cap (NOT a per-cycle trim target)

The length bound is **soft/hard**, mirroring `file_size_smell.md`
(ADR-0099) — it is a smell detector, NOT a metric to drive to an
exact number every cycle.

| Cap | Lines | Behavior |
|---|---|---|
| **Soft** | 100 | Target. Informational. A few lines over is fine — do NOT spend a cycle micro-trimming prose back to exactly 100. |
| **Hard** | 120 | MUST act before the handover commit: relocate stable content (Active-task workstreams, Key refs, durable invariants) to `CLAUDE.md` / a skill / a rule, OR drop closed-chunk detail. >120 = stale-prose accumulation, the failure mode a driving doc must avoid. |

**Why soft/hard** (2026-05-31, user-requested): the prior hard
`≤ 100` invited a wasteful per-cycle ritual of trimming 103→100 etc.
on every commit pair. The lean-doc *intent* is "don't let stale prose
accumulate," not "hit 100 exactly." Soft 100 / hard 120 captures the
intent: relax in the 100–120 band, act only at 120. When a large
`## Active bundle` (e.g. a multi-op emit sub-bundle) is live, the
100–120 band is expected; it shrinks at bundle close.

The trim action at hard cap is **relocation, not deletion of
signal**: stable facts move to a more permanent home (the bundle plan,
CLAUDE.md, a rule), so the handover stays a driving doc.

No mechanical gate enforces this (per the system-defenses-over-scripts
preference); `wc -l .dev/handover.md` at the handover-commit step is
the check — act only when it exceeds 120.

## Reviewer checklist

- [ ] No forbidden phrase from §1 table.
- [ ] No future-tense numeric prediction (§2).
- [ ] `Active task` / close-plan / bundle reference names a
      concrete next chunk, not an option list.
- [ ] `Open questions / blockers` lists testable external
      dependencies, not editorial pessimism.
- [ ] If numbers appear in debt row narrative, prefixed with
      `Hypothesis (verified at <SHA-or-date>): ...`.
- [ ] Length within soft/hard band (§6): ≤ 120 hard; relocate stable
      content (don't micro-trim) when 100 < N ≤ 120.

## Stale-ness

- If forbidden phrase list no longer matches drift patterns (new
  euphemism), re-derive from `git log -p .dev/handover.md
  --since="90 days ago"`.
- If a future Phase produces a similarly observable failing-
  fixture set, drop a `scripts/p<N>_<topic>_status.sh` before
  letting handover accumulate predictions about it.

## Related

- [`/continue` SKILL.md anti-patterns](../../skills/continue/SKILL.md)
- [`extended_challenge.md`](extended_challenge.md) — 3-step
  procedure for `Open questions / blockers` entries.
- [`investigation_discipline.md`](investigation_discipline.md) —
  hypothesis-enumeration when bugs span multiple cycles.

## Why this rule exists

§9.9-g-13 (2026-05-XX) prediction drift + 50+ null-op session
2026-05-22 + 13-cycle EH foundation chain 2026-05-26 — three
distinct failure modes that share the shape: handover prose that
deliberated when it should drive, predicted when it should
measure, or surrendered when work was autonomous-eligible.
