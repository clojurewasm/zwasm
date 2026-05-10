# continue — loop mechanics

> Sibling of `SKILL.md`. Holds the policy sections that are read
> once per session (push policy, self-perpetuation, parallel
> test gate) so `SKILL.md` itself stays focused on the per-task
> TDD steps.
>
> If you are reading `SKILL.md` and it references "Push policy",
> "Self-perpetuation", or "Parallel test gate", the canonical
> text lives here.

## Parallel test gate — file-logged pipeline

The Step 5 gate has **three hosts** (Mac aarch64, OrbStack
Ubuntu x86_64, windowsmini Windows x86_64) and **two distinct
cost shapes**:

- **Mac**: native, fast (≤ 60 s typical). Run synchronously and
  fail-fast — there is no value in backgrounding it because the
  next steps (commit / push) need its result inline.
- **OrbStack**: cross-machine, slow (~3-5 min typical). Run
  per-chunk in the background. SysV x86_64 ground truth.
- **windowsmini**: cross-machine + slow (~3-5 min) + flaky (D-028
  IPC timeout retry rate ~6%). Win64-specific divergence catcher.
  **Gated per-chunk via `scripts/should_gate_windows.sh`** — runs
  only when the diff plausibly hits Win64-specific code paths
  (ABI / calling convention / frame layout) OR 4+ commits have
  accumulated since the last windowsmini run. Otherwise deferred
  to the next checkpoint. Empirical justification: the §9.7 / §9.9
  run (15+ chunks of encoder + handler additions) saw zero
  windowsmini-unique findings vs Mac + OrbStack while adding
  ~30-45 min of cumulative wall-clock; this is rebalanced by
  the gating script. See lesson
  `.dev/lessons/2026-05-10-loop-overgating-retro.md`.

### Mandatory shape of the gate

This shape is **load-bearing**. A loop iteration that runs
OrbStack and windowsmini sequentially (or that re-invokes
`bash scripts/run_remote_windows.sh test-all` to re-read its
output) is in violation of this skill, even when the second
run happens to succeed.

```bash
# 1. Mac local: lint + unit tests (cheap, fast-fail). FOREGROUND.
zig build test                         > /tmp/mac.log     2>&1
zig build lint -- --max-warnings 0     > /tmp/mac-lint.log 2>&1

# 2. Source commit (Step 6).
git add <source-files>
git commit -m "<conventional commit>"

# 3. Sync the bench CI bot's commits, then push so windowsmini's
#    git-fetch picks up the new ref before its zig build starts.
#    The bot pushes `bench(ci): record <sha> [skip ci]` to
#    zwasm-from-scratch asynchronously after every loop push;
#    `--rebase --autostash` integrates those commits with zero
#    conflict (bench/results/*.yaml is disjoint from loop diffs)
#    and avoids the per-chunk non-fast-forward reject cycle.
git pull --rebase --autostash origin zwasm-from-scratch
git push origin zwasm-from-scratch

# 4. Decide whether windowsmini gate is required this chunk.
#    Returns 0 → run windowsmini; 1 → defer to next checkpoint.
if bash scripts/should_gate_windows.sh; then
    GATE_WINDOWS=1
else
    GATE_WINDOWS=0
fi

# 5. Kick OrbStack always; windowsmini conditionally. The two
#    background Bash tool calls (when both fire) MUST go in a
#    SINGLE tool message so the harness launches concurrently.
orb run -m my-ubuntu-amd64 bash -c \
  'cd /Users/shota.508/Documents/MyProducts/zwasm_from_scratch && zig build test-all' \
  > /tmp/orb.log 2>&1                                           # run_in_background: true
if [ "$GATE_WINDOWS" -eq 1 ]; then
    bash scripts/run_remote_windows.sh test-all \
      > /tmp/win.log 2>&1                                       # run_in_background: true
fi

# 6. WAIT for completion notifications (do NOT poll). When each
#    fires, Read /tmp/orb.log (and /tmp/win.log if gated) to
#    inspect the tail. NEVER re-invoke the gate command just to
#    extract output — the log file already has everything.

# 7. After successful windowsmini run, record HEAD as the new
#    last-tested commit so future deferral decisions reset.
if [ "$GATE_WINDOWS" -eq 1 ]; then
    bash scripts/should_gate_windows.sh --record
fi
```

**Why this exact shape:**

1. **Backgrounding is non-negotiable for OrbStack + windowsmini.**
   These commands take long enough that running them in the
   foreground blocks the loop for minutes. Run them with
   `run_in_background: true`. The harness sends a single
   completion notification per task; that is the signal to
   inspect the log.
2. **Single-message dispatch.** Both background Bash tool calls
   MUST go in **one assistant message** so the harness fires
   them concurrently. Two messages = two sequential dispatches
   = the second host waits for the first to finish.
3. **All output → log file.** Every host redirects stdout+stderr
   to a `/tmp/<host>.log`. The log is the single source of
   truth — read it with the Read tool when the notification
   fires. Re-running the build to re-read output is forbidden
   regardless of how convenient grep would have been.
4. **No polling, no sleep.** Once backgrounded, the harness
   notifies on completion. Sleep loops, retry-on-blank-output
   loops, and eager `tail` re-runs are all loop-discipline
   violations.

### When to skip the parallel pattern (rare)

Stay strictly serial only when:

- The diff touches load-bearing infra (build.zig, runner glue,
  zone deps, ROADMAP) AND a regression on either remote host
  is plausible enough that you want OrbStack's outcome before
  even attempting windowsmini.
- You are mid-incident (debugging a known regression) — running
  a clean serial baseline once is acceptable to localise.

In both cases, still log to file (`> /tmp/...log 2>&1`) so a
log-loss never forces a rerun.

### Re-runs are debt, not a tool

If a host's log shows a result you cannot interpret (truncated,
ambiguous, missing the failure line), the response is **Read
the log file again with offset/limit, or grep the file** —
never `bash scripts/run_remote_windows.sh test-all` a second
time hoping for cleaner output. The only legitimate reason to
re-run a remote gate is the D-028 flake (the IPC-timeout-only
failure pattern named in `.dev/debt.md` D-028); even then, the
re-run is bounded to once per chunk and the rationale is
documented in the commit message.

### Recovery on failure

- Mac green + remote (OrbStack / windowsmini) red → land a
  fix-up commit on top (`fix(p<N>): <one-line> — fixes
  <prev-sha>`) and re-run the parallel gate (one round, both
  hosts). Do not amend the pushed commit — `git push --force`
  is forbidden (§14).
- If the failing host's log shows the D-028 transient pattern
  (test runner failed to respond IPC timeout, no actual test
  failures), retry once before fix-up — and only via a
  one-off `bash scripts/run_remote_windows.sh test-all >
  /tmp/win-retry.log 2>&1` (background, file-logged).
- After fix-up lands, optionally squash the chain to a single
  meaningful commit on the next chunk's pre-push (`git rebase
  -i` locally, then push) — only when the squash is
  mechanical. Skip when in doubt.

### Step 7 integration

The Step 6 source-commit + push happens **before** the parallel
remote gate starts (so windowsmini's git-fetch resolves the new
ref). Step 7's handover update + ROADMAP `[x]` flip lands as a
follow-up commit + push **after** both remote hosts return
green. This keeps the gate's reference state fresh on
windowsmini's clone and amortises bookkeeping over the gate
wait.

## Push policy — autonomous, no approval

`git push origin zwasm-from-scratch` does **not** require user
approval inside this skill. The loop pushes its own commits.
Specifically:

- Every commit lands on the local `zwasm-from-scratch` branch via
  the per-task TDD loop (Step 6).
- Push happens at one of two points, whichever comes first:
  - End of a Step 5 cycle when `windowsmini` is the only host
    blocking and the script needs `origin` to be current. Push,
    re-run `bash scripts/run_remote_windows.sh`, evaluate gate.
  - End of every Step 7, after `[x]` flip + handover update —
    push so the gone-from-local risk is bounded by one task.
- **Pre-push rebase is the default**. Always run `git pull
  --rebase --autostash origin zwasm-from-scratch` immediately
  before `git push`. The bench CI bot pushes
  `bench(ci): record <sha> [skip ci]` commits to the same branch
  asynchronously after every loop push, so the local branch is
  almost always behind by 1–3 such commits when Step 6 / Step 7
  fire. Bench commits only touch `bench/results/*.yaml` (disjoint
  from loop diffs in `src/`, `.dev/`, `scripts/`, `test/`), so
  the rebase is conflict-free in practice. `--autostash` covers
  any uncommitted scratch in the worktree.
- A non-fast-forward error after pre-push rebase indicates **non-
  bench commits arrived between the rebase and the push** (rare;
  e.g. a parallel manual push). Re-run the same `git pull
  --rebase --autostash + git push` once. Only stop and surface
  to the user if the rebase itself raises a conflict —
  conflicts are bucket-2 of the stop whitelist (load-bearing
  history work needs user input).
- Push is **never to `main`** and **never `--force` /
  `--force-with-lease`** (denied at the harness level too).
- `--no-verify`, `--no-gpg-sign`, and any pre-commit / pre-push
  hook bypass remain forbidden (ROADMAP §14).

This overrides the "explicit user approval" wording elsewhere; that
wording exists to forbid drive-by pushes outside this loop, not to
gate the loop itself.

## Self-perpetuation — overnight loop

After every Step 7 commit lands and is pushed, the very last action
of the turn is to schedule the next iteration so the loop survives
without a fresh user message. **This is mandatory** — skipping it
silently re-introduces user-babysitting.

Use `ScheduleWakeup` with **`delaySeconds = 60` always**:

```
ScheduleWakeup(
  delaySeconds = 60,
  reason = "loop iteration <task-id> committed; re-arming for next task",
  prompt = "/continue"
)
```

`prompt = "/continue"` re-fires this skill from the resume
procedure on the next wakeup. (Do **not** pass
`<<autonomous-loop-dynamic>>` — that sentinel is for `/loop`
invocations started without any user prompt; this loop began
with the user's `/continue` and must be re-invoked the same
way.)

`ScheduleWakeup` is a deferred tool. On the first iteration of
a fresh session, load its schema via
`ToolSearch(query="select:ScheduleWakeup", max_results=1)` once
before the first call; subsequent calls in the same session do
not need re-loading.

If the user replies between iterations, that is automatic
intervention — the wakeup is consumed by the new turn and the
loop naturally resets to whatever the user said.

If a `ScheduleWakeup` call would be the second one of the same
turn (only one wakeup per turn is honoured), update the existing
one with `ScheduleWakeup` again instead of stacking.

End-of-turn checklist (every turn that ends with the task closed):

1. Step 6 commit landed.
2. Step 7 handover update + ROADMAP `[x]` flip committed.
3. `git push` succeeded.
4. `ScheduleWakeup` armed for the next iteration.
5. Final user-facing text is **one sentence** stating what just
   landed and what fires next. Do not write a long progress
   summary — it invites pause.
