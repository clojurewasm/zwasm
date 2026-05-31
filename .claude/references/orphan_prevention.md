# Orphan-prevention discipline — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/orphan_prevention.md`](../rules/orphan_prevention.md).

# Orphan-prevention discipline

Auto-loaded everywhere (paths `**`) — keep it lean.

## The rule

**Every `Bash(run_in_background: true)` that drives a long-running child
MUST be bounded by `timeout` (or a self-bounding launcher).** Long-running
= anything that could outlive one bash turn: the remote SSH gates, a
backgrounded `zig build test-all`, a bench sweep, a `nix develop --command`
build, a file watcher. Default 1800 s or a justified larger explicit value —
never omit the bound.

**Why it bites here**: `/continue` launches the remote gates
(`run_remote_ubuntu.sh` / `run_remote_windows.sh`, 3-5 min SSH) via
`run_in_background` and does **not** wait (ADR-0076 D2/D3; verified next
cycle at Step 0.7). A parent-session kill (auto-compact, interrupt, crash)
re-parents the script + its `ssh` child to PID 1, and the next cycle stacks
another SSH transport. On this Mac that compounds with Microsoft Defender
scanning `.zig-cache` / `zig-out` (debt **D-028** hyp #5) → load spikes, fan
events, garbled tool channel. Unbounded blocking readers (a `grep` on an
orphaned pipe spinning on `EAGAIN`) are the canonical fan-event recipe.

## Structural defense — the gates self-guard

`run_remote_ubuntu.sh` / `run_remote_windows.sh` source
`scripts/orphan_guard.sh` first: (a) reap any prior instance of the same
script + any `ssh <host>` client orphaned to **PID 1** (a live gate's own
child is untouched), then (b) re-exec under `timeout ${REMOTE_GATE_TIMEOUT:-1800}`.
So the loop's existing `bash scripts/run_remote_ubuntu.sh …` calls are bounded
**without changing the loop contract** (same `/tmp/ubuntu.log` happy-path
output). **Ad-hoc / manual** `run_in_background` (a one-off bg `zig build`, a
probe pipe) is NOT covered — wrap those in `timeout` yourself.

## Caveat: `timeout` does NOT propagate across SSH

`timeout` kills the local child (script / `ssh` client), not the command on
the **far** side. Mitigation in both gate scripts: `ssh -o
ServerAliveInterval=30 -o ServerAliveCountMax=4 …` — when the local client
dies, remote sshd drops the channel (and the remote build) within ~2 min. For
new remote long-runners, prefer a remote-side guard too (`ssh host 'timeout
600 cmd'`).

## Examples

- ❌ `ssh ubuntunote 'nix develop --command zig build test-all'`,
  `run_in_background` — raw SSH, no bound; orphaned remote build on kill.
- ❌ `(while true; do …; done) | grep x`, `run_in_background` — unbounded
  spin, the canonical fan event.
- ✅ `bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1`,
  `run_in_background` — self-guarded by `orphan_guard.sh`.
- ✅ `timeout 900 bash -c '…ad-hoc bg work…'`, `run_in_background` — manual,
  explicitly bounded.

## Discovery recipe

```sh
rg --no-heading -n 'run_in_background.*true' .claude/ scripts/ \
  | grep -vE 'orphan_prevention\.md|orphan_guard\.sh'
```

Each hit must route through a self-guarding script or carry an explicit `timeout`.

## Backstops & stale-ness

- **Cross-session backstop**: global SessionStart `~/.claude/hooks/cleanup_orphans.sh`
  reaps dev-tool orphans at etime > 30 min (the last-resort sweep).
- **Optional (user action, out of autonomous scope)**: excluding `.zig-cache` /
  `zig-out` from Defender real-time scan removes the scan-load half (mirrors the
  windowsmini D-028 fix).
- **Stale if**: a new long-runner surface lands without a `timeout`/guard;
  `timeout`/`gtimeout` leaves PATH (re-provision coreutils); healthy-gate p95
  climbs near 1800 s (raise via `REMOTE_GATE_TIMEOUT`).

## Related

`scripts/orphan_guard.sh` · `.dev/debt.md` D-028 (Defender rationale) ·
`.claude/skills/continue/LOOP.md` § "Self-perpetuation" + GATE.md ·
`~/.claude/CLAUDE.md` § "全プロジェクト共通" (global advisory + cleanup hook).

