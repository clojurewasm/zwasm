Loaded on demand from `.claude/rules/no_workaround.md`; not auto-loaded.

# No-workaround — v1 anti-patterns, spike boundary, reviewer checklist

The gate-rule holds the three principles + forbidden phrases. This file
holds the worked v1 anti-patterns, the spike-vs-workaround boundary,
the bar for genuine workarounds, and the reviewer checklist.

## Anti-patterns observed in v1 (to avoid in v2)

- **D116 abandoned address-mode folding**: tried, found ineffective,
  shipped anyway behind a flag, then reverted. The lesson: spike-then-
  measure is fine, but abandoned spikes belong in an ADR with
  `Status: Rejected`, not in the codebase.
- **W54 post-hoc liveness**: liveness was added late, broke x86 because
  the regalloc-stage IR shape implicitly assumed an absent invariant.
  In v2: liveness is a `?Liveness` slot in `ZirFunc` from day 1
  (ROADMAP §4.2 / P13).
- **D117 dual-entry self-call workaround**: introduced because inst_ptr
  cache + callee-saved competition couldn't be expressed cleanly. In
  v2: explicit `RegClass.inst_ptr_special` slot in
  `src/jit/reg_class.zig` from Phase 7.

## When spike work is OK

A spike is a learning experiment, not a delivery. Boundaries:

- ≤ 1 day of effort.
- Lives on a separate branch or a `private/spikes/` directory
  (gitignored).
- Outcome → ADR (Accepted with a follow-up ROADMAP entry, OR Rejected
  with the lessons captured).
- **Never** lands as a flag-gated workaround on `main` (via a develop/<slug> PR).

## When a workaround is genuinely needed

Sometimes the upstream is broken (Zig 0.16 stdlib bug, OS quirk). The
bar:

1. ADR documents the workaround with: upstream issue link, expected
   expiry condition, removal plan.
2. Workaround is contained in one file (preferably `src/platform/` for
   OS quirks, `src/util/` for stdlib gaps).
3. A `// TODO(adr-NNNN): remove once <condition>` comment marks it.
4. `audit_scaffolding`'s "lies" check periodically verifies the removal
   condition still hasn't fired.

## Reviewer checklist (apply during Step 4 Refactor / pre-commit)

- [ ] Does this fix the actual cause, or paper over the symptom?
- [ ] Is there an ADR for any non-obvious choice?
- [ ] Are abandoned alternatives noted (in ADR Alternatives section)?
- [ ] Will this still make sense in 6 months? (If not, what condition
      makes it expire?)
