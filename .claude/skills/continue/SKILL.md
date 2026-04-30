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
(they're investigated and fixed in-line if the fix is local), an
auto-compact does not stop the loop (the `PostCompact` hook
re-injects the resume brief; pick the loop up from there), an empty
task queue does not stop the loop (open the next phase).

If you are unsure whether to stop, the answer is **don't**. The user
will interrupt if needed.

## Resume procedure (run on every session pickup)

1. Read `.dev/handover.md`. (The `SessionStart` hook already prints it.)
2. Read `.dev/ROADMAP.md`:
   - Look up the **Phase Status** widget at the top of §9 — it
     names the IN-PROGRESS phase and its first open `[ ]` task.
   - Open that phase's `§9.<N>` task table and confirm the table's
     first `[ ]` matches the widget. If they disagree (drift), the
     widget is wrong; trust the table and update the widget.
   - If §9.<N>'s task table is missing/empty, the phase has not
     been opened yet; expand it first (mirror the previous phase's
     structure).
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

The gate command is whatever the active §9.<N>.<task>'s exit
criterion specifies. The defaults are:

- Phase 0 / 0.1, 0.2, 0.3 — `zig build` only (build verify).
- Phase 0 / 0.5 onward and Phase 1+ — `zig build test-all` (or the
  narrower `zig build test` plus phase-relevant `test-spec` /
  `test-e2e` / etc. as they land).

Run on all available hosts in a single message with parallel Bash
tool calls:

- `zig build <step>` (Mac aarch64 host)
- `orb run -m my-ubuntu-amd64 bash -c 'cd /Users/shota.508/Documents/MyProducts/zwasm_from_scratch && zig build <step>'`
  (Linux x86_64 via OrbStack — Bash timeout ≥ 600000 ms for cold
  builds)
- For Windows: `bash scripts/run_remote_windows.sh <step>` — the
  script `git fetch + reset --hard origin/zwasm-from-scratch` on
  the windowsmini clone at `~/Documents/MyProducts/zwasm_from_scratch`
  and then runs `zig build <step>` there. It exercises the latest
  pushed origin state, so push first if you need a local commit
  reflected in the gate.

All hosts must be green to proceed. If any output exceeds ~200
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

### Step 7 — Handover update (always)

1. Update `.dev/handover.md` to reflect the just-completed task and
   the next one (1-2 lines + retrievable identifiers). This is the
   only mandatory documentation step — zwasm v2 does not maintain
   the per-task / per-concept chapter cadence (P9).
2. Mark `[x]` for the just-completed task in ROADMAP §9.<N>. Leave
   the Status column SHA blank (`[x]`) — do **not** spawn a second
   commit just to write the SHA you can't know yet. The SHA pointer
   is **batch-backfilled at phase close** (see §0.7 procedure
   below). The commit message itself references `§9.<N> / N.M`, so
   `git log --grep="§9.<N> / N.M"` is the canonical lookup; the
   Status SHA is convenience, not load-bearing.

   **§18 self-check before this edit** (the PreToolUse hook will
   also re-print this when you save): `[x]` flips and SHA backfills
   are *routine status updates*, no ADR needed. But if the same
   commit also touches §9 phase scope, exit criteria, §11 layers,
   §14 forbidden list, or any §1/§2/§4/§5 text — that part is a
   *deviation*; file `.dev/decisions/NNNN_<slug>.md` first per
   ROADMAP §18.2 and reference it in the commit message.
3. Continue immediately to the next task's Step 0. Context-fill
   management is the harness's job, not yours — see "Auto-compact
   recovery" below.

(Per-task notes in `private/notes/` are **optional**. Write them
only if the survey or stuck-points are non-trivial enough to be
worth re-reading later.)

## Auto-compact recovery

You **cannot** invoke `/compact` yourself — it is a user slash
command. The harness fires `autoCompactEnabled` when context fills,
silently summarising prior conversation. After compact:

- The system prompt and skill listing survive.
- The `PostCompact` hook re-emits `scripts/print_handover_brief.sh`
  output (language policy + handover.md + last 3 git commits) into
  the conversation, mirroring SessionStart. That brief is your
  recovery anchor.
- Tool-result detail (test logs, file dumps) does **not** survive
  — only the harness summary remains.

Two implications for the loop:

1. **Treat the PostCompact brief as a fresh resume.** Re-read
   `.dev/handover.md`, locate the active task in ROADMAP §9, run
   `git log -3` and `git status`, then continue from Step 0 of that
   task. If `git status` shows uncommitted changes that look
   in-flight, decide: complete and commit, or `git stash` and
   restart the task (cheaper than guessing what was half-done).
2. **Update `handover.md` before any long subagent call.** Step 7
   is not the only time you should write it. Before:
   - Dispatching an Explore subagent for a multi-file survey.
   - Running a long test suite (`zig build test-all` past a few
     minutes).
   - Any `run_in_background` Bash that may outlast the next compact.
   …flush the current state to `handover.md` so post-compact
   recovery has fresh ground truth. The cost is a 30-second edit;
   the value is not losing the loop's bearings overnight.

The loop is designed so mid-task auto-compact loses at most one
task's worth of in-flight Steps 0-3. Steps 4-6 (refactor / gate /
commit) end with an artifact in git; Step 7 ends with handover
updated. Anchor on those.

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
3. **Backfill SHA pointers for §9.<N>'s task rows.** For each `[x]`
   row whose Status column is bare (no SHA), fill the SHA with:

   ```
   git log --grep="§9.<N> / <N.M>" --pretty=%h | head -1
   ```

   Land this in **one** commit (e.g. `chore(p<N>): backfill §9.<N>
   SHA pointers`). This is the single phase-level commit where SHA
   bookkeeping is paid; per-task Step 7 stays SHA-free so it
   doesn't generate per-task backfill commits.
4. **Open §9.<N+1>**: update the **Phase Status** widget at the top
   of §9 (mark §9.<N> as `DONE`, §9.<N+1> as `IN-PROGRESS`); expand
   §9.<N+1>'s task table inline (mirror §9.<N>'s structure: a
   numbered `[ ]` table with the same Status column shape); update
   handover.md to point at §9.<N+1>'s first task.
5. Resume §9.<N+1>'s Step 0 immediately. If the harness compacts
   mid-transition, the PostCompact brief recovers state.

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
