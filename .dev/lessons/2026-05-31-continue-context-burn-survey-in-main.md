# Context burn: Step-0 survey run in main context (the dominant lever)

2026-05-31. A `br_on_cast` Cycle-B Step-0 survey burned ~83% of the pinned
200K window in ~10 min before any code was written. Honest attribution of
where the tokens went, biggest lever first:

1. **DOMINANT, fully controllable — survey ran inline in MAIN context.**
   ~14 `Bash` greps (several with large dumps: the `dispatch_collector_ops.zig`
   ~100-file listing, src-wide `grep` results) + ~6 `Read`s of 100–130-line
   ranges, **compounded across ~20 assistant turns** (every turn re-carries all
   prior tool results). CLAUDE.md "Per-task TDD loop" + `textbook_survey.md`
   both say **Step 0 defaults to an Explore subagent (medium)**. Dispatching one
   would have read the same files in ITS context and returned a ~300–400-line
   summary — collapsing ~100K+ of reads into ~5K in main. This was a process
   miss, not a structural one. It is the #1 lever by a wide margin.

2. **Semi-fixed — auto-loaded `.claude/rules/*.md`.** 16 files / ~2090 lines
   load in full on the first Zig-source-editing turn (`paths:` glob match) =
   ~18–24K every session. The 4 longest dominate: `test_discipline` (361),
   `extended_challenge` (270), `abi_callee_saved_pinning` (193),
   `platform_panic_vs_error` (193). Stub-split (the `comment_as_invariant` /
   `libc_boundary` pattern, ADR-0118 D2) of the longest few reclaims ~10K/session.
   Already tracked as "Deferred" in memory `feedback_context_budget_posture`.

3. **Background — large source files.** `runner.zig` (1894), the `op_control_*.zig`
   pair, `dispatch_collector_ops.zig` inflate every targeted `Read` and every
   `src/`-wide grep dump. Not separately actionable beyond #1's discipline.

## Levers, in priority order

- **Fork Step-0 surveys to an Explore subagent — DEFAULT, not optional.** Single
  biggest win. The summary (not the file dumps) is what main context needs.
- Prefer narrow `grep -n` + tight `Read` windows over file-listing greps; route
  big greps to a file then read ranges (global rule already says this for logs).
- Stub-split the 4 longest always-on rules behind `references/` (see #2).

## Why it bites here

The 200K pin (`CLAUDE_CODE_DISABLE_1M_CONTEXT=1`) makes auto-compact fire fast.
A survey that should cost ~5K in main instead fills the window and forces a
compact mid-task — the exact failure mode the pin + PostCompact handover were
meant to make cheap, defeated by doing the heavy reading in the wrong place.

Related: [[feedback_context_budget_posture]] · `textbook_survey.md` §"Survey
discipline" · CLAUDE.md §"Context budget (autonomous loop)".
