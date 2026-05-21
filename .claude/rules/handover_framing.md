---
paths:
  - ".dev/handover.md"
---

# Handover framing discipline

Auto-loaded when editing `.dev/handover.md`. Codifies the
2026-05-22 retrospective: a session of ~50+ consecutive
null-op heartbeat cycles where the loop deferred to "user
judgment" on work that was actually autonomous-eligible.
The skill's [`anti-patterns`](../skills/continue/LOOP.md)
section already forbids "Big next task, natural stop" and
"User can /continue when ready", but **the anti-pattern grep
fired on phrases, not on semantics** — handover used different
words for the same surrender.

## The rule

`.dev/handover.md` is a **driving document**, not a
**deliberation document**. Every entry must either:

1. Describe a concrete autonomous next chunk (`emit` /
   `infrastructure` / `survey` / `architectural` / `test-only`
   per [`LOOP.md` Chunk types](../skills/continue/LOOP.md)), OR
2. Name a specific code/test/spec dependency that is
   provably waiting on external input.

**Anything else is forbidden framing.** The loop reads
handover to decide what to do next, not whether to do
anything.

## Forbidden phrases (grep-enforced)

The following appearances anywhere in `.dev/handover.md` are
**block-level findings** that the resume procedure (`/continue`
Step 1) MUST repair before proceeding:

| Phrase | Why forbidden | Replace with |
|---|---|---|
| `user-judgment territory` | Treats the whole pickup as a stop signal | Concrete `emit` / `infrastructure` chunk description |
| `Next pickup (user-judgment)` | Same as above | `Active task — <chunk-id>` |
| `wait for natural trigger` | Passive surrender; null-op recipe | Drop the option entirely OR file the trigger as a debt row with `Status: blocked-by: <named external event>` |
| `wait for ... fixtures` | Same as above | Same |
| `needs commitment to` | Frames work as requiring user buy-in | Just describe the work as the next chunk |
| `substantial multi-cycle ... work` | Multi-cycle is just the cycle count, not a defer reason | Remove the size adjective; let the loop iterate |
| `deep <X> work or wait` | Re-introduces the "wait" option | Drop `or wait`; describe the chunk |
| `pivot to <X> OR <Y>` | Implies user picks the branch | Pick the branch in handover itself; the loop executes |

The **single allowed** use of `user-judgment` in handover is
for **§18 deviation**: an entry that points at a load-bearing
ROADMAP / ADR amendment requiring user review at ADR-flip
time. Even then, the **draft is autonomous**; only the
`Proposed → Accepted` flip is user-gated.

## Anti-pattern: 3-option pickup

The 2026-05-22 incident had handover present:

> (a) §9.13-0 windowsmini reconcile ... — substantial
>     multi-cycle Win64-side work.
> (b) §18 amendment of §9.12-F exit criterion.
> (c) Wait for natural trigger events.

All three options are wrong as written:

- (a) describes the work then **provides an excuse not to do
  it** ("substantial multi-cycle").
- (b) is legitimate user-judgment for the ADR-flip **but**
  the ADR draft itself is autonomous.
- (c) is just "do nothing" with a justification clause.

**Replacement shape**: pick (a) and (b) **both** as parallel
autonomous tracks. Drop (c). Re-arm and proceed.

## What handover IS for

- Naming the **first chunk** the next resume should execute
  (typed per LOOP Chunk types; sized per the bundle/split
  rules).
- Carrying forward **`now` debts** (always discharged at
  resume Step 0.5 before chunk start).
- Recording **provable external blockers** with a named
  testable condition (e.g. "blocked-by: upstream Zig 0.17
  release"). The barrier-dissolution check at resume Step
  0.5 walks these.
- Pointing at the **`phase*_close_plan.md`** doc when one is
  active (close-plan override per `/continue` Step 1a).

## What handover is NOT for

- Listing multiple "options" for the next session — the
  loop already picked an option by reading handover.
- Editorial framing about how hard the next work is.
- Estimating cycle count (no numeric predictions — per
  [`no_handover_predictions.md`](no_handover_predictions.md)).
- Surfacing "I don't know what to do" — that's a bucket-2
  stop and belongs in `Open questions / blockers` with a
  specific investigation Step 1-3 attempt per
  [`extended_challenge.md`](extended_challenge.md).

## How `/continue` enforces this

The resume procedure (Step 1) grep-scans handover for the
forbidden phrase list above. On hit:

```
grep -nE "user-judgment territory|wait for natural trigger|
wait for .* fixtures|needs commitment to|substantial multi-cycle|
deep .* work or wait" .dev/handover.md
```

If non-empty → **the FIRST chunk of the resume is the handover
rewrite itself**, not the prose-suggested chunk. The rewrite
removes the forbidden framing and replaces with a concrete
chunk per this rule. Then the loop proceeds normally.

This is by design: the framing fix is cheap (~5 minutes) and
catastrophic to skip (a single forbidden phrase can cost a
night of null-ops, as 2026-05-22 demonstrated).

## Reviewer checklist

When reviewing a handover.md commit:

- [ ] No forbidden phrase from the table above.
- [ ] `Active task` (or close-plan reference) names a
      concrete next chunk, not an option list.
- [ ] `Open questions / blockers` lists testable external
      dependencies, not editorial pessimism.
- [ ] Total length ≤ 100 lines.

## Related

- [`no_handover_predictions.md`](no_handover_predictions.md)
  — forbids numeric / behaviour predictions in handover.
- [`/continue` SKILL.md anti-patterns](../skills/continue/LOOP.md)
  — phrase-level grep for "Big next task, natural stop" etc.
  This rule is the **semantic-level companion** that catches
  surrender re-framed in new words.
- [`extended_challenge.md`](extended_challenge.md) — the
  3-step procedure for `Open questions / blockers` entries.
- [`spike_lifecycle.md`](spike_lifecycle.md) — `private/spikes/`
  governance; spike artifacts don't belong in handover.

## Stale-ness

This rule is stale if:

- The forbidden phrase list no longer matches actual
  handover drift patterns (a new euphemism for surrender
  drifted in). Re-derive the list from `git log -p
  .dev/handover.md --since="90 days ago"` and surface
  candidates.
- `/continue` Step 1 grep mechanism is changed and the
  forbidden list isn't ported.
