---
name: continue
description: Resume fully autonomous work on zwasm-from-scratch and drive the per-task TDD loop until the user intervenes or a problem is identified that genuinely cannot be solved. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Reads handover, finds next task, runs tests, then immediately enters the TDD loop with no "go" gate, no Phase-boundary stop, and no per-task confirmation. Auto-runs adaptive audit_scaffolding inline and continues into the next Phase without prompting.
---

# continue

Pick up where the previous session left off and **drive the iteration
loop fully autonomously**. The user invoked `/continue` precisely so
they would not have to babysit every checkpoint.

This skill is **opinionated about context discipline**: it delegates
heavy reads to subagents, compacts proactively, and resets at phase
boundaries. The zwasm v2 project is multi-phase; without these
disciplines, late-session quality degrades.

## When to stop, when to keep going

Default = **keep going**. Push approval is the only checkpoint that
is always user-required. Beyond that, **stop only when**:

- The user explicitly intervenes (interrupts, types a new directive,
  asks to pause).
- A problem you genuinely cannot solve has been identified — the
  root cause is unclear after investigation, or a load-bearing
  trade-off is needed that conflicts with ROADMAP §2 / §14.

There is no other stop condition. **Phase boundaries do not stop the
loop**, audit_scaffolding "block" findings do not stop the loop
(they're investigated and fixed in-line if the fix is local), context
fill near 60 %+ does not stop the loop (`/compact` and continue), an
empty task queue does not stop the loop (open the next phase).

If you are unsure whether to stop, the answer is **don't**. The user
will interrupt if needed.

## Resume procedure (run on every session pickup)

1. Read `.dev/handover.md`. (The `SessionStart` hook already prints it.)
2. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9. If none, take the first PENDING.
   - In that phase's expanded §9.<N> task list, find the first `[ ]`
     task. If §9.<N> is missing/empty, the phase has not been opened
     yet; expand it first.
3. `git log --oneline -10` — identify the last commit.
4. `zig build test` (Phase 0+) — confirm the build is green. From
   Phase 1, also run `zig build test-spec`. From Phase 6, also run
   the differential subset. **If output is large (>200 lines), run
   via subagent and ask only for pass/fail + the first failure.**
5. Summarise to the user in 5–10 lines:
   - Phase (number + name)
   - Last commit
   - Test status
   - Next task (number + name + exit criterion)
6. **Immediately proceed into the TDD loop.** Do not wait for "go" —
   `/continue` itself is the go signal.

## Per-task TDD loop

For each `[ ]` task in §9.<N>, run **Steps 0 → 7** in order. **Step
0 defaults to subagent**; Step 5 may delegate when output is large;
the rest run in main.

### Step 0 — Survey (subagent: Explore, default mode "medium")

Skip only if the task is *clearly* a continuation of a prior task
(refactor, rename, doc-only). Otherwise: dispatch one Explore
subagent to survey the textbooks. **Default brief**:

> Survey how `<concept>` is implemented in:
> - `~/Documents/MyProducts/zwasm/src/...` (v1, ~65K LOC) — read,
>   never copy
> - `~/Documents/OSS/wasmtime/cranelift/...` and/or
>   `~/Documents/OSS/wasmtime/winch/...` (Rust reference)
> - `~/Documents/OSS/zware/src/...` (Zig idiom)
> - `~/Documents/OSS/wasm3/source/...` (M3 IR / interpreter idiom)
> - `~/Documents/OSS/wasm-c-api/include/wasm.h` (when ABI is at
>   stake)
> - `~/Documents/OSS/regalloc2/` (when JIT regalloc is at stake)
> - `~/Documents/OSS/zig/lib/std/...` (when stdlib API is in
>   question)
>
> Return 200–400 lines: file pointers, key data shapes, idioms used,
> what each codebase does *differently* and why. Do **not** copy
> code; describe the design space. Highlight 2–3 decisions where
> zwasm v2 should likely diverge based on ROADMAP §2 principles.

The summary lands in `private/notes/<phase>-<task>-survey.md`
(gitignored, optional persistence). Read it, then proceed to Step 1.

See [`.claude/rules/textbook_survey.md`](../../rules/textbook_survey.md)
for when to skip Step 0 and how to avoid being pulled by upstream
styles. The prohibition on copy-paste from v1 is in
[`.claude/rules/no_copy_from_v1.md`](../../rules/no_copy_from_v1.md).

### Step 1 — Plan

One sentence in chat: the smallest red test that captures the next
behaviour. No permission needed.

### Step 2 — Red

Write the failing test (Edit / Write — auto-accepted). Run it;
confirm red.

### Step 3 — Green

Minimal code to pass. Resist over-design — the next refactor pass
is cheap.

### Step 4 — Refactor

While green. Apply only structural improvements that do not change
behaviour.

### Step 5 — Test gate (three hosts where applicable)

Run **all** in a single message with parallel Bash tool calls:

- `zig build test` (Mac aarch64 host)
- `orb run -m my-ubuntu-amd64 bash -c 'cd /Users/shota.508/Documents/MyProducts/zwasm_from_scratch && zig build test'`
  (Linux x86_64 via OrbStack — Bash timeout ≥ 600000 ms for cold
  builds)
- `ssh windowsmini "cd zwasm_from_scratch && zig build test"`
  (Windows x86_64 native — Phase 0 smoke; Phase 14+ wraps in
  `scripts/run_remote_windows.sh`)

All three must be green to proceed. If any output exceeds ~200
lines, delegate to a Bash subagent and ask for "pass/fail + first
failure only"; otherwise inline.

OrbStack VM setup: `.dev/orbstack_setup.md`. Windows SSH: `.dev/windows_ssh_setup.md`.
If a host is absent (`error: machine not found` for OrbStack;
`ssh: connection refused` for windowsmini), surface to the user —
do not attempt to provision autonomously.

### Step 6 — Source commit

`git add` only the source files; `git commit -m "<type>(<scope>):
<one line>"`. The pre-commit gate runs. If the gate blocks for a
genuine reason, fix and re-stage.

Never `git commit --no-verify` (forbidden by ROADMAP §14).

### Step 7 — Handover update + context budget check

1. Update `.dev/handover.md` to reflect the just-completed task and
   the next one (1-2 lines + retrievable identifiers). This is the
   only mandatory documentation step — zwasm v2 does not maintain
   the per-task / per-concept chapter cadence (P9).
2. Mark `[x]` for the just-completed task in ROADMAP §9.<N>; append
   the source SHA in the Status column.
3. Estimate the current context fill. If above ~60 % of the active
   model's window:
   - Run `/compact` with a save brief listing: active phase, next
     task, architectural constraints in flight.
   - Re-read `handover.md` after compact.
4. If below 60 %, continue immediately to the next task's Step 0.

(Per-task notes in `private/notes/` are **optional**. Write them
only if the survey or stuck-points are non-trivial enough to be
worth re-reading later.)

### Repeat

Steps 0–7 for each `[ ]` task in §9.<N>.

## Phase boundary — inline, no stop

A Phase closes when the last `[ ]` in §9.<N> flips to `[x]`. At
that point:

1. Optional: invoke `audit_scaffolding` (slash command). It produces
   `private/audit-YYYY-MM-DD.md`. If a `block` finding is local and
   obvious, fix in the next commit; otherwise note in handover and
   continue.
2. Optional: run built-in `simplify` on `git diff <phase-start>..HEAD
   -- src/`. Apply behaviour-preserving suggestions; queue larger
   ones in `handover.md`.
3. **Open §9.<N+1>**: flip the §9 phase tracker; expand §9.<N+1>
   inline (mirror §9.<N>'s structure); update handover.md to point
   at §9.<N+1>'s first task.
4. If context is high, run `/compact`. Otherwise, immediately resume
   §9.<N+1>'s Step 0.

The phase-boundary review steps are **opportunistic, not mandatory**.
Apply them when the scaffolding seems to need it; skip when the
work has been clean.

## Subagent delegation cheatsheet

| Trigger                               | Action                                              |
|---------------------------------------|-----------------------------------------------------|
| Survey ≥ 1 reference codebase / OSS  | Step 0 — Explore subagent                          |
| Test output > 200 lines               | Step 5 — Bash subagent (run_in_background if long) |
| Search across > 5 files               | Explore subagent                                    |
| Single-file edit, < 200 lines context | Stay in main                                        |

Default rule: **subagent fork on context isolation, not on
importance**.

## What NOT to invoke during the loop

- `simplify` per source commit — overkill; queue for occasional
  passes.
- `review` (PR-style) per commit — overkill; reserve for pre-push
  or pre-tag.
- `audit_scaffolding` per task — adaptive cadence (when scaffolding
  feels off, when refactors land, before release tags).

## Model selection (dual-model)

- **Per-task TDD loop (Steps 1–6)**: current session's model — Opus
  4.7 is fine.
- **Phase boundary chain (multi-agent fan-out, when invoked)**:
  prefer **Opus 4.6** for the long-context audit / simplify
  subagents — Opus 4.7's MRCR v2 retrieval is known to degrade
  above ~100k tokens versus 4.6. Sonnet 4.6 is a viable
  cost-efficient alternative.

When unsure, default to subagent inheriting the parent model; flip
to Opus 4.6 only if a long-context task underperforms.
