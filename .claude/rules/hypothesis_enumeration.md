---
paths:
  - ".dev/handover.md"
  - ".dev/debt.md"
  - ".dev/lessons/*.md"
---

# Hypothesis enumeration discipline for hard-bug investigations

Auto-loaded when editing handover / debt / lessons. Pairs with
[`no_handover_predictions.md`](no_handover_predictions.md) (which
forbids numeric predictions about as-yet-unwritten code) and
[`extended_challenge.md`](extended_challenge.md) (which forbids
deferring on cost). This rule covers the **investigation-time**
hypothesis-tracking discipline.

## When this rule applies

Any bug whose investigation spans **more than 1 cycle** of
the `/continue` loop. Single-cycle bisects don't need this
overhead; multi-cycle investigations do — they're the case
where "next investigator re-explores from scratch" is
expensive.

The trigger ≈ same as a `now` debt row with `Status: now`
that survived one resume without being closed.

## The rule

When the bug is still open after the cycle ends, the
handover / debt row MUST carry an **enumerated hypothesis
list**. Build it in this order:

**Step 0 — Framing challenge** (run BEFORE enumerating any
hypothesis; per
[`2026-05-18-debt-dedup-grep-before-file.md`](../../.dev/lessons/2026-05-18-debt-dedup-grep-before-file.md)):

1. Grep `.dev/debt.md` for the affected source file /
   function names + symptom keywords ("stale" / "off-by-one"
   / "wrong-register" / etc.) — does a `now`-status row
   already document this bug class under a different
   framing?
2. Grep `.dev/lessons/INDEX.md` for the same keywords —
   is there a prior investigation that already mapped this
   space?
3. If either grep hits, **dedup**: update the existing
   debt row / cite the existing lesson; do NOT open a fresh
   investigation. The inherited framing from the discovering
   chunk's narrative is often too narrow and hides the
   class-overlap.

Then for each genuinely-new hypothesis:

1. Numbered hypothesis name (e.g., "(1) PAC", "(2)
   siglongjmp re-entry").
2. Each hypothesis's **predicted observable signature** —
   what you'd see if it were true. (Concrete: a register
   value, a fault address pattern, a stderr line, a
   directory count.)
3. Each hypothesis's **distinguishing probe** — the cheapest
   single experiment that would confirm / reject it.

When a hypothesis is **rejected** by a cycle's probe,
mark it `~~rejected~~` with the rejecting commit's SHA, but
**keep it in the list**. Future cycles must not re-walk
rejected paths.

When a NEW hypothesis surfaces mid-investigation, **append
it to the list with the next number** and the same shape
(signature + probe). Don't insert in the middle.

## Why this rule exists (motivation)

D-142 (Mac aarch64 cross-module SEGV) ran **6 cycles** of
investigation before root cause was identified. Cycles 1-5
each rejected one hypothesis via a targeted probe; cycle 6
converged because the prior 5's rejection evidence was
recorded explicitly in the debt row and the lesson file.
Without that discipline, cycle 6 would have re-walked the
PAC and siglongjmp branches.

The opposite anti-pattern (observed in §9.9-g-13 per
[`no_handover_predictions.md`](no_handover_predictions.md)):
handover claims a SPECIFIC cause ("the 16 fails are alias
case") without enumerating alternatives. The next cycle
implements the prescribed fix, finds it doesn't move
counts, and has to start over.

## Template (paste into debt row or lesson body)

```markdown
**Hypotheses** (numbered; rejected entries marked ~~strikethrough~~
with rejecting SHA):

1. ~~<name>~~ — REJECTED <SHA> via <probe>. <evidence summary>.
2. ~~<name>~~ — REJECTED <SHA> via <probe>. <evidence summary>.
3. <name> (active) — predicted signature: <what we'd see>.
   Distinguishing probe: <single experiment>.
4. <name> (active) — ...
5. <name> (NEW, from cycle N): ...

**Leading hypothesis** (if narrowed): <#N>. **Next probe**:
<concrete one-cycle experiment>.
```

## Where to keep the list

- **Open + currently investigating**: in the debt row body
  (one debt = one bug = one hypothesis list). Handover
  references the debt row (`see D-NNN`); does not duplicate.
- **Closed (root cause identified)**: promote to a lesson
  under `.dev/lessons/`. Keep the enumerated list as the
  audit-trail of what was ruled out — the lesson's
  re-derivability value depends on future investigators
  seeing WHY each branch failed.

## Reviewer checklist (apply when reviewing a multi-cycle
investigation's handover / debt edits)

- [ ] Are hypotheses numbered + named?
- [ ] Does each rejected hypothesis cite the rejecting SHA
      and the probe that rejected it?
- [ ] When a new hypothesis is added, does it come with
      (a) predicted signature and (b) distinguishing probe?
- [ ] Does the active "leading hypothesis" name a SINGLE
      next probe that would either narrow or reject it?
- [ ] When the investigation closes, was the enumerated
      list preserved in the lesson (not lost to handover
      compaction)?

## Stale-ness

If a multi-cycle debt row exists with NO enumerated
hypothesis list, file an `audit_scaffolding` finding (or
update inline if mid-`/continue`). The pattern of
"investigation lost across resumes" is the failure mode
this rule prevents; an investigation without a list is at
high risk of re-walking rejected paths.
