# Bug-fix-time survey: grep siblings before changing code

Auto-loaded when editing Zig source. Codifies the "twin-largest"
regret from the 2026-05-04 retrospective: when applying a bug
fix, the loop has historically jumped from symptom → diff without
checking whether the same shape exists elsewhere — landing the
fix at the symptom, not the population.

## The rule

Before editing code to fix a bug, run a **same-class-cases
survey**. The discipline is:

1. Identify the symptom's **shape** (a symbol, a control-flow
   pattern, a type, an opcode group, a field-merge logic).
2. **Grep** the codebase for that shape.
3. Apply the fix at every site where the shape recurs, OR
   document why a site is exempt.

This complements `textbook_survey.md` (task-start design
survey) by addressing **bug-fix-time** survey discipline.

## Why this rule exists

Case study — D-027 (the if-result merge fix, sub-7.5c-vi):

The first cycle landed the merge-aware label-stack fix in `if`
control flow. After commit, broader tests revealed the same
shape was needed for `block (result T)` and `loop (result T)`.
Sub-7.5c-vii spent another cycle re-applying the same fix to
the sibling cases. **A bug-fix-time grep for "label result
arity" sites would have surfaced both siblings before the first
commit landed.**

Other historic instances of the same pattern:

- ADR-0014 §6.K.5 (`Label.arity` / `branch_arity` split) —
  applied to `block` first; `loop` divergence surfaced as a
  separate bug.
- v1's W54 post-mortem — single hoist site fixed; the fix was
  re-derived multiple times before it generalised.

## The 3-step procedure

When you've identified the bug and are about to type the fix:

### Step 1 — Grep the **symbol**

If the bug touches a function / field / type, grep the symbol
across `src/`:

```bash
rg -n 'Label\.merge_top_vreg' src/
rg -n 'fn handleEnd' src/
rg -n 'pushed_vregs\.pop' src/
```

Read the call sites — does the bug's logic apply at each?

### Step 2 — Grep the **shape**

The symbol may be specific; the bug's *shape* often spans
multiple symbols. Examples:

- "control flow op that merges arms with arity > 0" — applies to
  `if`, `block`, `loop`, `try`, `try_table`.
- "spill load before resolveGpr" — applies wherever
  `gprLoadSpilled` is called before `resolveGpr` consumes the
  same vreg.
- "ZirOp emitting a fixup byte_offset" — applies to every label
  fixup, every call fixup, every br_table fixup.

Express the shape as a regex if possible; grep with it; read
the surrounding code at each hit.

### Step 3 — Cite ROADMAP §14 forbidden-list nearby

If the symbol or shape is **near a ROADMAP §14 entry** (single
slot dual meaning, ARM64-only feature, dispatch-table bypass),
the bug fix is also a §14 risk surface. Re-read the relevant §14
entry and the corresponding `.claude/rules/*.md` file before
editing.

For example: any fix to `Label`, `merge_top_vreg`, `arity`,
`branch_arity` is in the §14 "single slot serving two semantic
axes" neighborhood (per `single_slot_dual_meaning.md`). A grep
for those terms is the bug-fix-time check.

## When to skip this rule

- **Trivial fixes**: typos in comments, format strings, a missing
  `null` check on a single optional whose source is unambiguous.
- **Type-system errors**: the compiler already enumerates every
  site needing change; manual grep is redundant.
- **Refactor-rename bugs**: `replace_all` in IDE / Edit tool
  takes care of the population.

If unsure: run the grep. The cost is 30 seconds; the cost of
missing a sibling case is one re-fix cycle (often 1+ commits +
test reruns + 3-host gate).

## Reviewer checklist (apply during PR review)

- [ ] When the diff fixes a bug, did the author cite "same-class
      cases checked" in commit message OR the diff itself
      touches every same-class site?
- [ ] If only one site is touched but siblings exist, is the
      reason for selectivity explicit (e.g. "loop-result has
      different semantics — separate fix in next commit") OR
      surfaced as a debt entry?
- [ ] If the bug touches a §14 forbidden-list neighborhood, is
      the corresponding rule (single_slot_dual_meaning,
      no_workaround, etc.) cited?

## How this rule interacts with other rules

| Rule                          | Interaction                                                                                         |
|-------------------------------|-----------------------------------------------------------------------------------------------------|
| `textbook_survey.md`          | That rule = task-start design survey; this rule = bug-fix-time grep within `src/`. Triggers are mutually exclusive — at any moment one applies, never both. |
| `single_slot_dual_meaning.md` | Step 3 of this rule cites §14's slot-dual-meaning entry when the bug is in that neighborhood.       |
| `no_workaround.md`            | Bug-fix-time grep often surfaces "we worked around this elsewhere too" — escalate per no_workaround. |
| `edge_case_testing.md`        | When the grep surfaces a sibling boundary, add an edge-case fixture in the same commit.             |

## Anti-patterns this rule rejects

- **"I'll fix it here and check the rest later"** — "later" is
  not a discipline; the next /continue cycle picks the next `[ ]`
  row, not the deferred sibling.
- **"This bug is local to this opcode"** — opcodes are rarely
  truly isolated when control flow / regalloc / merge points are
  involved. Grep first, claim "local" second.
- **"The test catches the regression"** — if the test exists
  *for* the sibling site, then the sibling already had the bug
  AND the test, and the grep would still have surfaced it.
