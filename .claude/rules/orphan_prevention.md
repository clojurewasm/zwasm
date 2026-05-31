---
paths:
  - "scripts/**"
  - ".claude/skills/**"
  - "test/runners/**"
  - "build.zig"
---

# Orphan-prevention discipline

> Lean stub (ADR-0118 D2). Full why / examples / discovery recipe / backstops: [`../references/orphan_prevention.md`](../references/orphan_prevention.md).
> (Glob narrowed 2026-05-31 from `**` — bg-launching code lives in scripts/skills/runners; the global `~/.claude/CLAUDE.md` advisory + SessionStart `cleanup_orphans.sh` cover the rest broadly.)

## Invariant

- **Every `Bash(run_in_background: true)` that drives a long-running child MUST
  be bounded by `timeout`** (default 1800 s, or a justified explicit value) OR a
  self-bounding launcher. Long-running = anything that could outlive one bash
  turn (remote SSH gates, bg `zig build test-all`, bench sweep, `nix develop`
  build, file watcher).
- `timeout` does NOT propagate across SSH — pair with `ssh -o
  ServerAliveInterval=30 -o ServerAliveCountMax=4` (or a remote-side `timeout`).

## Enforcement

The remote gates self-guard via `scripts/orphan_guard.sh` (reap PID-1 orphans +
re-exec under `timeout ${REMOTE_GATE_TIMEOUT:-1800}`). Ad-hoc bg work is NOT
covered — wrap it in `timeout` yourself. Discovery:
`rg --no-heading -n 'run_in_background.*true' .claude/ scripts/`.

## Key cases

- ❌ raw `ssh host 'nix develop --command zig build test-all'` bg (orphaned remote build).
- ❌ `(while true; do …; done) | grep x` bg (unbounded spin = the canonical fan event).
- ✅ `bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1` bg (self-guarded).
- ✅ `timeout 900 bash -c '…ad-hoc bg…'` bg.
- Cross-session backstop: SessionStart `~/.claude/hooks/cleanup_orphans.sh` reaps dev-tool orphans at etime > 30 min.

Full why (Defender D-028 compounding) + backstops + stale-ness: [`../references/orphan_prevention.md`](../references/orphan_prevention.md).
