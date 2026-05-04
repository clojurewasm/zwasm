---
name: continue
description: Resume fully autonomous work on zwasm-from-scratch and drive the per-task TDD loop until the user intervenes or a problem is identified that genuinely cannot be solved. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Reads handover, finds next task, runs tests, then immediately enters the TDD loop with no "go" gate, no Phase-boundary stop, and no per-task confirmation. Auto-runs adaptive audit_scaffolding inline, continues into the next Phase without prompting, pushes its own commits to origin/zwasm-from-scratch, and re-arms itself via ScheduleWakeup so overnight / no-reply sessions keep iterating.
---

# continue

Pick up where the previous session left off and **drive the iteration
loop fully autonomously, indefinitely, without user babysitting**.
The user invoked `/continue` precisely so they can walk away — go to
sleep, leave the desk, or just stop replying — and expect to come
back to a long chain of green commits, not a "shall I proceed?"
prompt.

This skill is **opinionated about context discipline and
self-perpetuation**: it delegates heavy reads to subagents, compacts
proactively, resets at phase boundaries, **pushes its own work**, and
**re-arms itself** so the loop survives even when the user is not
present. The zwasm v2 project is multi-phase; without these
disciplines, late-session quality degrades and overnight progress
stops.

## Stop conditions — strict whitelist

You may stop the autonomous loop **only** for one of these two
reasons. Anything else is a non-stop condition and you must keep
going.

1. **The user explicitly intervenes** — a new directive arrives,
   they interrupt, they ask you to pause, or they type a message
   that is incompatible with continuing the loop. The user typing
   nothing is *not* an intervention.
2. **A genuinely unsolvable problem is identified** — root cause
   unclear after investigation; OR a load-bearing trade-off is
   needed that conflicts with ROADMAP §2 (P/A) or §14 (forbidden
   list); OR a required external host (`my-ubuntu-amd64`,
   `windowsmini`) is provably absent. Document the blocker in
   `handover.md` "Open questions / blockers", then stop. Do not
   stop on a hunch — only after investigation.

### Non-stop conditions (explicit, exhaustive)

The following are **not** stop conditions. Encountering any of them
means you continue the loop. If you find yourself reaching for one
as justification to stop, you are violating this skill.

- A Phase boundary just closed (§9.<N> → §9.<N+1>).
- The §9.<N> task table is empty and needs to be opened.
- A previous task ended with a clean commit and the next task is
  "big".
- N commits have already landed in this run (any N).
- Context fill is high or auto-compact seems imminent (the
  `PostCompact` hook recovers; see "Auto-compact recovery").
- An `audit_scaffolding` finding is `block` and the fix is local —
  fix it inline.
- An `audit_scaffolding` finding is `block` and the fix is *not*
  local — file an ADR via §18, queue the fix in handover, then
  continue.
- The next task requires an Explore / Plan / Bash subagent — fork
  one and continue.
- The next task requires `git push` — push and continue (see
  "Push policy" below).
- A test gate failed on `windowsmini` because the commit is not
  yet on `origin/zwasm-from-scratch` — push and re-run, then
  continue.
- Multiple `[x]` flips and SHA backfills are pending — batch them
  and continue.
- You produced a long status summary and feel like a "good place
  to stop" — that is exactly when you must keep going.
- The user has not replied for a long time — that is the **point**
  of the skill.

If you are unsure whether to stop, the answer is **don't**. The user
will interrupt if needed.

## Destructive-action policy — autonomous within scope

The harness's general "ask before destructive" guidance does **not**
gate the autonomous loop on the following local, reversible actions.
Run them without confirmation:

- `rm <file>` / `rm -r <dir>` / `rm -rf <dir>` for paths under
  `private/`, `.zig-cache/`, `zig-out/`, `/tmp/`, scratch
  artifacts you yourself just created (e.g. smoke-test files
  under `.claude/`), and survey notes you no longer need.
- `mv` / `cp` / `mkdir` / `rmdir` for the same scope.
- `git stash` / `git restore <path>` / `git checkout -- <path>`
  to discard uncommitted local edits when re-starting a task
  after auto-compact (see "Auto-compact recovery").
- `git reset <commit>` (mixed / soft) on the local
  `zwasm-from-scratch` branch when the working tree is yours
  alone. **`git reset --hard` remains denied** by
  `.claude/settings.json` and is a bucket-2 stop if genuinely
  needed.

Out of scope (still ask the user / stop):

- `rm -rf /`, `rm -rf ~/`, `rm -rf $HOME`, `rm -rf .git` —
  denied in `.claude/settings.json`; if you somehow need them,
  that is bucket 2 of the stop whitelist.
- Anything outside the project working tree and the
  `additionalDirectories` list in settings.json.
- `git push --force` / `--force-with-lease` — denied; main push
  forbidden by §14.

## Loop mechanics — see `LOOP.md`

The two policy sections that govern the autonomous loop —
**Push policy** (when / how `git push` happens without user
approval) and **Self-perpetuation** (the `ScheduleWakeup` re-arm
contract) — live in the sibling file `LOOP.md`. Read it once
per session at the top of the resume procedure; it does not
change between iterations.

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
3. `git log --oneline -10` and `git status -sb` — identify the last
   commit and whether anything is in flight.
   - If `git status` is clean and origin is ahead-or-equal: proceed.
   - If `git status` shows uncommitted changes that look in-flight:
     decide — complete and commit, or `git stash` and restart the
     task (cheaper than guessing what was half-done).
   - If local is ahead of origin: push immediately (no approval
     needed; see "Push policy") before the next Step 0.
4. **Step 0.4 — Lesson scan**. Read `.dev/lessons/INDEX.md`. For
   the active task's domain (interpreter, cross-module imports,
   ABI, build.zig, validator, …), grep the keyword column for
   pre-recorded learnings. Read every matching lesson **before**
   starting Step 0 (Survey). This is cheap (≤ 30 s) and prevents
   re-paying spike costs that prior cycles already paid. See
   `.claude/rules/lessons_vs_adr.md` for the lesson concept.
5. **Step 0.5 — Debt sweep**. Read `.dev/debt.md`. For every
   row with `Status: now`, attempt to discharge it before
   starting the active task. **Effort estimate is irrelevant**;
   only structural impossibility (a `blocked-by: <X>` barrier
   that the row's author named) prevents discharge. Discharge
   commit messages take the form `chore(debt): close D-NNN
   <one line>`; remove the row from `.dev/debt.md` in the same
   commit. If a `blocked-by` row's structural barrier was
   removed by recent work, flip its Status to `now` and
   discharge alongside. New debts discovered during the active
   task are appended at task close (Step 7), not mid-task.
6. `zig build test` (Phase 0+) — confirm the build is green. From
   Phase 1, also run `zig build test-spec`. From Phase 7, also run
   the differential subset. **If output is large (>200 lines), run
   via subagent and ask only for pass/fail + the first failure.**
7. **One-sentence** status to the user (phase + last commit + next
   task). Do **not** produce a multi-line summary; that is a stop
   antipattern (see "Self-perpetuation").
8. **Immediately proceed into the TDD loop.** Do not wait for "go" —
   `/continue` itself is the go signal, and so is the wakeup that
   fired it.

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

Re-open `.dev/ROADMAP.md` §9.<N> task table and confirm the first
`[ ]` row is still the one in `.dev/handover.md` Active task. If
they disagree (someone — user or a prior loop iteration —
re-prioritised between turns), trust ROADMAP and update handover;
do not silently follow the stale handover.

One sentence in chat: the smallest red test that captures the next
behaviour. No permission needed.

**Deviation watch.** If your Plan would touch §1, §2 (P/A), §4
(architecture / Zone / ZirOp), §5 (layout), §9 phase scope or
exit criteria, §11 layers, or §14 forbidden list — STOP. Write
`.dev/decisions/NNNN_<slug>.md` first per ROADMAP §18.2, then
return to Step 2. Discovering the deviation at Step 7 (commit
time) is too late — Step 7's §18 self-check exists as a backstop,
not as the primary checkpoint.

### Step 2 — Red

Write the failing test (Edit / Write — auto-accepted). Run it;
confirm red.

### Step 3 — Green

Minimal code to pass. Resist over-design — the next refactor pass
is cheap.

### Step 4 — Refactor

While green. Apply only structural improvements that do not change
behaviour.

**Debt observation.** While editing, if you see a smell that doesn't
fit this task's surgical scope (an obviously-incorrect docstring,
a deprecated comment, a `catch {}` cluster, a positional API ripe
for `Opts` struct refactor, etc.), do NOT silently leave it. Decide:

- If discharging it now stays behaviour-preserving and is mechanical
  (≤ 5 minutes of typing) — fix it inline with the rest of Step 4.
- Otherwise — **append a debt entry to `.dev/debt.md`** with
  `Status: now` (so the next resume's Step 0.5 picks it up). New
  debts are never invisible; if you saw it, future-you must see
  it too.

The `now` vs `blocked-by` discipline is **structural impossibility
only**, not effort estimation. See `.dev/debt.md`'s discipline
header.

**Workaround / extended-challenge check.** If the way you got
green involved papering over a missing tool / file / capability
("added a SKIP-X-MISSING fallback", "skipped a host's gate") —
re-read `.claude/rules/extended_challenge.md`. The 3-step
procedure (Confirm → Self-provision → Document specifically)
may not have been walked. If it wasn't, walk it now before
proceeding to Step 5. A workaround without paired investigation
is forbidden; a workaround with a debt entry naming the
structural barrier is acceptable.

After refactor, before moving to Step 5, run the **Mac-host lint
gate** (ADR-0009) once:

```sh
zig build lint -- --max-warnings 0
```

If this fails, the diff used a deprecated stdlib API. Fix at the
call site (consult `.claude/rules/zig_tips.md` for the canonical
0.16 replacement) and re-run before Step 5. The lint gate is
Mac-only — it is **not** repeated on OrbStack / windowsmini, since
deprecation findings are platform-independent.

### Step 5 — Test gate (three hosts)

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
  pushed origin state, so **push first** if a local commit needs
  to be reflected. Pushing is autonomous — see "Push policy".

All hosts must be green to proceed. If any output exceeds ~200
lines, delegate to a Bash subagent and ask for "pass/fail + first
failure only"; otherwise inline.

OrbStack VM setup: `.dev/orbstack_setup.md`. Windows SSH:
`.dev/windows_ssh_setup.md`. If a host appears absent (`error:
machine not found` for OrbStack; `ssh: connection refused` for
windowsmini), the bucket-2 stop whitelist requires "provably
absent" — and what counts as "provable" is defined by
`.claude/rules/extended_challenge.md`. Walk the 3-step procedure
(Confirm → Self-provision → Document specifically) **first**;
only stop if Steps 1+2 actually ran and confirmed the absence
is structural. "I assume it's absent" is not a proof.

Provisioning failures or missing tooling on a host that's
otherwise reachable (e.g. windowsmini's wasmtime-stub case
from §9.6 / 6.F) are usually not stop conditions — file a
debt entry naming the structural barrier and proceed.

### Step 6 — Source commit

`git add` only the source files; `git commit -m "<type>(<scope>):
<one line>"`. The pre-commit gate runs. If the gate blocks for a
genuine reason, fix and re-stage.

Never `git commit --no-verify` (forbidden by ROADMAP §14).

### Step 7 — Handover update + push + re-arm

1. **Replace** (do not append to) `.dev/handover.md`'s `Current
   state` block + `Active task` table:
   - `Current state`: 5 lines max — Phase, last commit SHA + one-
     line gist, next task id. **Delete** any per-task prose older
     than the active task (it's already in `git log --grep="§9.<N>
     / N.M"`, the canonical lookup; do not duplicate).
   - `Active task`: refresh the chunk progress table (or
     equivalent) so the **next** chunk is marked `**NEXT**`.
   - Keep the whole file ≤ 100 lines. Anything stable across
     phases (file shape, skill catalogue, layout) belongs in
     `CLAUDE.md` or the relevant skill / rule file, not here.

   This is the only mandatory documentation step — zwasm v2 does
   not maintain the per-task / per-concept chapter cadence (P9).
2. Mark `[x]` for the just-completed task in ROADMAP §9.<N>.
   Leave the Status column SHA blank (`[x]`) — the SHA pointer
   is **batch-backfilled at phase close**. The commit message
   itself references `§9.<N> / N.M`, so `git log --grep="§9.<N>
   / N.M"` is the canonical lookup; the Status SHA is convenience,
   not load-bearing.

   **§18 self-check before this edit** (the PreToolUse hook will
   also re-print this when you save): `[x]` flips and SHA
   backfills are *routine status updates*, no ADR needed. But if
   the same commit also touches §9 phase scope, exit criteria,
   §11 layers, §14 forbidden list, or any §1/§2/§4/§5 text — that
   part is a *deviation*; file `.dev/decisions/NNNN_<slug>.md`
   first per ROADMAP §18.2 and reference it in the commit
   message.
3. **Append new debt entries to `.dev/debt.md`**. Any debt
   observation surfaced during Step 4 that wasn't discharged
   inline gets a row here, with `Status: now` (default) or
   `Status: blocked-by: <specific structural barrier>`. New
   debts are appended at task close, not mid-task — this keeps
   the active task's diff clean. If `.dev/debt.md` was modified,
   include it in the next git add. Update `.dev/lessons/INDEX.md`
   + add lesson files if a learning emerged (per
   `.claude/rules/lessons_vs_adr.md`).
4. `git add .dev/ROADMAP.md .dev/handover.md [.dev/debt.md]
   [.dev/lessons/...]` and commit (`chore(p<N>): mark §9.<N> /
   N.M [x]; retarget handover at N.M+1`).
5. **Push**. `git push origin zwasm-from-scratch`. No approval
   needed (see "Push policy"). If push fails non-fast-forward,
   that is bucket 2 of the stop whitelist.
6. **Re-arm** the loop with `ScheduleWakeup` (see
   "Self-perpetuation" for the call shape and `delaySeconds`
   choice). This is mandatory.
7. Final user-facing text: one sentence. State the closed task
   id and the next task id. Do not write a status table.

(Per-task notes in `private/notes/` are **optional and not
load-bearing**. Write them only if the survey or stuck-points
are non-trivial enough to be worth re-reading later. If a
private note describes a load-bearing decision, promote it
to an ADR or a lesson per `lessons_vs_adr.md`. The audit and
resume procedures do not read `private/` as authoritative.)

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
   `git log -3` and `git status`, then continue from Step 0 of
   that task. If `git status` shows uncommitted changes that look
   in-flight, decide: complete and commit, or `git stash` and
   restart the task. **Do not stop** — auto-compact is explicitly
   in the non-stop list.
2. **Update `handover.md` before any long subagent call.** Step 7
   is not the only time you should write it. Before:
   - Dispatching an Explore subagent for a multi-file survey.
   - Running a long test suite (`zig build test-all` past a few
     minutes).
   - Any `run_in_background` Bash that may outlast the next
     compact.
   …flush the current state to `handover.md` so post-compact
   recovery has fresh ground truth. The cost is a 30-second edit;
   the value is not losing the loop's bearings overnight.

The loop is designed so mid-task auto-compact loses at most one
task's worth of in-flight Steps 0-3. Steps 4-6 (refactor / gate /
commit) end with an artifact in git; Step 7 ends with handover
updated and a wakeup armed. Anchor on those.

### Repeat

Steps 0–7 for each `[ ]` task in §9.<N>. Then Phase boundary
(below). Then §9.<N+1>'s Step 0. The loop never voluntarily exits
this cycle.

## Phase boundary — inline, no stop

A Phase closes when the last `[ ]` in §9.<N> flips to `[x]`. At
that point:

1. Optional: invoke `audit_scaffolding` (slash command). It
   produces `private/audit-YYYY-MM-DD.md`. If a `block` finding
   is local and obvious, fix in the next commit. If a `block`
   finding requires a load-bearing change, file an ADR via §18,
   queue in handover, then continue. **Either path continues the
   loop** — phase boundaries are non-stop.
2. Optional: run built-in `simplify` on `git diff
   <phase-start>..HEAD -- src/`. Apply behaviour-preserving
   suggestions; queue larger ones in `handover.md`.
3. **Backfill SHA pointers for §9.<N>'s task rows.** For each
   `[x]` row whose Status column is bare (no SHA), fill the SHA
   with:

   ```
   git log --grep="§9.<N> / <N.M>" --pretty=%h | head -1
   ```

   Land this in **one** commit (e.g. `chore(p<N>): backfill §9.<N>
   SHA pointers`). This is the single phase-level commit where
   SHA bookkeeping is paid; per-task Step 7 stays SHA-free so it
   doesn't generate per-task backfill commits.
4. **Open §9.<N+1>**: update the **Phase Status** widget at the
   top of §9 (mark §9.<N> as `DONE`, §9.<N+1> as `IN-PROGRESS`);
   expand §9.<N+1>'s task table inline (mirror §9.<N>'s structure:
   a numbered `[ ]` table with the same Status column shape);
   update handover.md to point at §9.<N+1>'s first task.
5. Push, re-arm via `ScheduleWakeup`, and resume §9.<N+1>'s Step
   0 immediately. If the harness compacts mid-transition, the
   PostCompact brief recovers state.

The phase-boundary review steps are **opportunistic, not
mandatory**. Apply when the scaffolding seems to need it; skip
when the work has been clean. Either way, the loop continues.

## Subagent delegation cheatsheet

| Trigger                               | Action                                              |
|---------------------------------------|-----------------------------------------------------|
| Survey ≥ 1 reference codebase / OSS   | Step 0 — Explore subagent                           |
| Test output > 200 lines               | Step 5 — Bash subagent (run_in_background if long)  |
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

## Anti-patterns observed in past sessions (do not repeat)

These are concrete failure modes from prior runs. Reading them once
beats inventing new ways to stop.

- **"Big next task, natural stop"** — picking up that the next
  task looks bigger and ending the turn so the user can issue
  another `/continue`. Forbidden — the whole point is no
  babysitting. Push the commit, re-arm, continue.
- **"N commits is enough"** — landing several tasks then writing
  a progress summary as a soft pause. Forbidden — write one
  sentence and re-arm.
- **"Push needs approval"** — interpreting CLAUDE.md's push
  language as a per-loop gate. Forbidden — push policy is
  autonomous inside this skill.
- **"windowsmini gate not exercised, defer"** — declaring local
  Mac + OrbStack good and stopping until next session. Forbidden
  — push and run windowsmini before deciding it is a real
  blocker.
- **"User can /continue when ready"** — the closing line that
  re-introduces babysitting. Forbidden — the closing line is the
  `ScheduleWakeup` and one short sentence.
- **"Auto-compact might be coming, safer to stop"** — forbidden;
  PostCompact recovers, the loop continues.
