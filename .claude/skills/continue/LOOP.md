# continue — loop mechanics

> Sibling of `SKILL.md`. Holds the two policy sections that
> are read once per session (push policy + self-perpetuation
> wake-up loop) so `SKILL.md` itself stays focused on the per-
> task TDD steps.
>
> If you are reading `SKILL.md` and it references "Push policy"
> or "Self-perpetuation", the canonical text lives here.

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
- Push is **never to `main`** and **never `--force`**. If a
  non-fast-forward error is raised, stop and surface to the user
  (this is bucket 2 of the stop whitelist — unsolvable without
  user input on history rewriting).
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

Use `ScheduleWakeup`:

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
not need re-loading. Pick `delaySeconds` per the cache-window
rule:

- **60–270s** when work is actively flowing — Step 5 finished
  green, Step 6 + 7 just landed, and the next task is small. Keeps
  the prompt cache warm.
- **1200–1800s** when a long subagent / build / audit was just
  kicked off in the background and you need to wait for it.
- Never choose 300s — pay the cache miss properly or stay under
  it.

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
