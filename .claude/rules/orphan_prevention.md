---
paths:
  - "**"
---

# Orphan-prevention discipline

Auto-loaded everywhere. zwasm's `/continue` loop runs the remote
gates (`run_remote_ubuntu.sh` / `run_remote_windows.sh` — 3-5 min SSH
long-runners) via `Bash(run_in_background: true)` and **does not wait**
(ADR-0076 D2/D3 — the result is verified at the next cycle's Step 0.7).
A parent-session kill (auto-compact, interrupt, overnight crash)
re-parents the script + its `ssh <host>` child to PID 1; the next cycle
launches a fresh one, stacking SSH transports.

On this Mac that pile compounds with **Microsoft Defender**: `wdavdaemon`
continuously scans the `.zig-cache` / `zig-out` build artifacts (observed
~20 % CPU even idle), the same real-time-scan interference already
root-caused on windowsmini (debt **D-028** hyp #5, fixed there by
exclusion paths). Orphan zig/ssh processes + Defender scan → host load
spikes, fan events, and a garbled tool channel.

## The rule

**Every `Bash(run_in_background: true)` invocation that drives a
long-running child MUST be bounded by `timeout` (or a self-bounding
launcher).** Long-running = anything that could outlive one bash turn:
the remote SSH gates, a backgrounded `zig build test-all`, a bench
sweep, a `nix develop --command` build, a file watcher. Pick the
default 1800 s or a justified larger explicit value — never omit the
bound.

zwasm's known long-runner surfaces:

- `scripts/run_remote_ubuntu.sh` / `run_remote_windows.sh` — SSH gates.
- A backgrounded `zig build test-all` (rare; foreground is the norm).
- `nix develop --command …` (fixture gen `#gen`, remote build) — pins a
  toolchain, can hang on a cold Nix substituter fetch.

## Structural defense — the gates self-guard

`run_remote_ubuntu.sh` / `run_remote_windows.sh` source
`scripts/orphan_guard.sh` as their first action, which (a) reaps any
prior instance of the same script + any `ssh <host>` client orphaned to
**PID 1** (precise — a live gate's own child is untouched), then (b)
re-execs the script under `timeout ${REMOTE_GATE_TIMEOUT:-1800}`. So the
loop's existing `bash scripts/run_remote_ubuntu.sh …` invocations are
bounded **without changing the loop contract** — no LOOP.md / GATE.md /
SKILL.md edit, same `/tmp/ubuntu.log` `[run_remote_ubuntu] OK (HEAD=…)`
output on the happy path.

This makes the discipline structural for the high-frequency surface.
**Ad-hoc / manual** `run_in_background` invocations (a one-off bg `zig
build`, a probe pipe) are NOT covered by the guard — wrap those in
`timeout` yourself.

## Failure modes the bound defeats

1. **Parent-session-kill orphan**: Claude's bash subprocess exits on
   session interrupt; a `run_in_background: true` child re-parents to
   PID 1 and lives forever without a `timeout`.
2. **Stacked SSH transports**: the loop's "don't wait, verify next
   cycle" means a still-alive prior gate + a new launch coexist. The
   guard's reap-prior makes "one gate at a time" structural.
3. **Hung-stdin poll spin**: a `grep` (or any blocking reader)
   downstream of an orphaned pipe spins on `EAGAIN` and burns a core —
   the canonical Mac fan-event recipe.

## Caveat: `timeout` does NOT propagate to the remote

`timeout` kills the immediate child (the local script / `ssh` client),
not a command running on the **other side** of the SSH channel. A
killed `run_remote_ubuntu.sh` can leave `zig build` running on
ubuntunote. Mitigation, applied in both gate scripts: `ssh -o
ServerAliveInterval=30 -o ServerAliveCountMax=4 …` — when the local
client dies, the remote sshd drops the channel (and the remote build)
within ~2 min. For new remote long-runners, prefer a remote-side guard
too (`ssh host 'timeout 600 cmd'`).

## Backstops & layers

- **Intra-session** (this rule + `orphan_guard.sh`): reap-on-launch,
  bound at 1800 s. The layer the 30-min cross-session threshold is too
  coarse for (a stale 5-min gate is already an orphan).
- **Cross-session**: the global SessionStart
  `~/.claude/hooks/cleanup_orphans.sh` reaps dev-tool orphans at
  etime > 30 min (zig / ssh / nix / spinning grep). Shared with all
  projects; the last-resort sweep.
- **Mac Defender exclusion (optional, user action — out of autonomous
  scope)**: excluding `.zig-cache` / `zig-out` from Defender real-time
  scan (`mdatp` CLI / managed config) would remove the scan-load half of
  the compounding. This edits global/managed system config, so it is
  NOT done by the loop — recommend it to the user (mirrors the
  windowsmini D-028 exclusion-path fix).

## Counter-examples

❌ `Bash(command: "ssh ubuntunote 'nix develop --command zig build
test-all'", run_in_background: true)` — raw SSH, no bound. Orphaned
remote build on session kill.

❌ `Bash(command: "(while true; do …; done) | grep x",
run_in_background: true)` — unbounded loop, the canonical fan event.

✅ `Bash(command: "bash scripts/run_remote_ubuntu.sh test-all >
/tmp/ubuntu.log 2>&1", run_in_background: true)` — self-guarded by
`orphan_guard.sh` (reap + 1800 s bound + keepalive).

✅ `Bash(command: "timeout 900 bash -c '…ad-hoc bg work…'",
run_in_background: true)` — manual invocation, explicitly bounded.

## Discovery recipe

```sh
rg --no-heading -n 'run_in_background.*true' .claude/ scripts/ \
  | grep -vE 'orphan_prevention\.md|orphan_guard\.sh'
```

Each hit that drives a long-running child must either route through a
self-guarding script or carry an explicit `timeout`.

## Stale-ness

- A new long-runner surface lands (a WASM runtime daemon in tests, a
  backgrounded bench harness) without a matching `timeout` / guard.
- `timeout` / `gtimeout` both leave this Mac's PATH (the guard degrades
  to unbounded — re-provision coreutils).
- The 1800 s default proves wrong (healthy gate p95 climbs near it —
  bench at a Phase boundary; raise via `REMOTE_GATE_TIMEOUT`).

## Related

- `scripts/orphan_guard.sh` — the sourced reap + self-bound prelude.
- `~/.claude/CLAUDE.md` § "全プロジェクト共通" — global orphan advisory
  + the SessionStart cleanup hook.
- `.dev/debt.md` D-028 — windowsmini Defender real-time-scan
  interference (hyp #5 CONFIRMED; exclusion-path fix).
- `.claude/skills/continue/LOOP.md` § "Self-perpetuation" +
  GATE.md — the backgrounded-gate invocation contract this guards.
