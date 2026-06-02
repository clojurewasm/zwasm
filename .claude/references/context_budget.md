# Context budget — full rationale + guard post-mortem

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → not auto-loaded;
> read on demand). Pointer from `CLAUDE.md` § "Context budget".

This file holds the long-form reasoning the `CLAUDE.md` bullet points at.
It is deliberately NOT a `.claude/rules/` file: rules are injected in full
on every matching edit, references are read only when the topic is live.

## The problem (2026-05-31)

The 200K window hit 100% fast and recycled often. Root-cause comparison
against `ClojureWasmFromScratch` (which did not bloat) found:

- **Dominant**: `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` pinned **200K**; CW ran the
  default **1M**. Same content fills 200K 5× faster. The window *cap*, not
  the working set, was the felt pain.
- **Secondary, structural**: `.claude/rules/*.md` are auto-injected IN FULL
  by Claude Code's native `paths:` frontmatter glob. Editing one `src/**/*.zig`
  file pulled ~2000 lines of rule prose into context — a fixed tax paid every
  edit and re-paid after every compaction. (The subagent that first measured
  this miscalled it "~1%": 2000 lines of markdown ≈ ~20-25K tokens ≈ **~10-12%
  of a 200K window**, lines ≠ tokens.)
- **Spiky**: huge `.dev/debt.yaml` rows (D-198 / D-202 are 100+ lines each) flood
  main context when grepped; long subagent reports return into main context.

## The decisions

1. **Window: back to 1M** (removed the env pin 2026-05-31). The autonomous
   `/continue` loop still wants lean context for token cost, but the lever is
   structural discipline (below), not a hard window cap that just makes the
   meter hit 100% sooner. Cost trade-off: a 1M turn can accumulate more context
   before auto-compact (the old "~835K balloon" concern) — accepted; cost is
   managed by the discipline below, not by squeezing the window.

2. **Rules → lean stub + reference** (ADR-0118 D2 pattern, completed for the
   big rules). Each `.claude/rules/*.md` carries only: the load-bearing
   invariant, the grep/script enforcement command, and a pointer to its
   `.claude/references/<name>.md` detail. Verbose rationale / worked examples /
   reviewer checklists move to the reference (no frontmatter → on-demand).

3. **Path globs tightened** so a rule loads only when genuinely relevant
   (arch-emit rules → `src/engine/codegen/**`; not `**`).

## Survey-guard post-mortem — intent preserved, mechanism removed

`scripts/survey_budget_guard.sh` (PreToolUse hook, added 2026-05-31, removed
same day) tried to force "fork heavy surveys to a subagent" by counting
main-context Read/Grep ops and hard-blocking past a threshold. **Confirmed
structurally broken**:

- **Wrong metric**: counted op *count*, not token *volume*. One 2000-line Read
  or one giant-debt-row grep = 1 op, under threshold — exactly the bloat it
  missed. A PreToolUse hook cannot see a tool's *output* size, so a
  volume-guard cannot be built this way.
- **Reset bug**: keyed state by `session_id`; subagent contexts get distinct
  ids, so the "fork → reset" never touched the main counter. The guard fired
  *after* forks; only a manual `echo 0 >` unblocked it.
- **Fires inside subagents**: truncated the very deep-reading the fork is for
  (a config-comparison subagent stopped early "hit the budget" → returned
  incomplete data).
- **Read-before-Edit deadlock**: Edit/Write need a prior Read, but Read was the
  gated op; the "Edit/Write resets" escape can't fire before the blocked Read.
- **Blind to the real costs**: auto-loaded rules, tool logs, returned subagent
  reports — none counted.

**The intent is real and kept** — it now lives as discipline, not a hook:

- **Fork big reads/surveys to an Explore subagent** AND instruct it to return a
  **≤30-line conclusion** (the report returns into main context too — a 200-line
  report negates the fork). See `.claude/rules/textbook_survey.md`.
- **Never grep whole giant debt rows into main** — query the specific row /
  field; keep `.dev/debt.yaml` rows lean (long investigations → a lesson or a
  reference, debt row points at it).
- **Read only the slice you need** of a large file (offset/limit), not the whole
  file, when you already know the region.

## Audit hook

`audit_scaffolding §G` (or a future `scripts/check_rule_size.sh`): flag any
`.claude/rules/*.md` whose auto-loaded body exceeds ~60 lines without a
matching `.claude/references/<name>.md` — that is the stub-pattern regression
signal.
