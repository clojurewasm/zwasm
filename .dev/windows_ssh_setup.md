# Windows SSH (`windowsmini`) Setup

zwasm v2's third native platform — Windows x86_64 — is verified
locally via SSH to a host called `windowsmini`. This is the same
mini PC and SSH alias the user already maintains for zwasm v1's
Windows verification (see v1 `.dev/memo.md` "C-g step 5
prerequisite" entry). For v2, the host is reused as-is.

## Why SSH instead of WSL or VM

Per ROADMAP §11.5 / A8, Windows uses **native tooling** — not WSL,
not Wine — so the runtime exercises native PE/COFF binaries, MSVC
ABI, and the actual Windows page-protection / signal handling.
WSL re-tests Linux; Wine emulates incompletely. The SSH approach
gives a real x86_64 Windows host with minimal local-Mac overhead.

## Prerequisites on `windowsmini`

The mini PC must already have, per zwasm v1's setup:

- Git for Windows (supplies bash + curl + tar + unzip)
- PowerShell 7
- Python 3.x
- winget
- The pinned tools (`zig`, `wasm-tools`, `wasmtime`, WASI SDK,
  `hyperfine`) — for Phase 0 the user's existing zwasm v1 install
  on `windowsmini` (its `scripts/windows/install-tools.ps1`)
  satisfies this. zwasm v2 wires its own `scripts/windows/`
  installer at Phase 13+.

## SSH alias

The Mac's `~/.ssh/config` should already have:

```
Host windowsmini
    HostName <ip-or-hostname>
    User <user>
    IdentityFile ~/.ssh/<keyfile>
```

Verification:

```bash
ssh windowsmini "echo ok && zig version"
```

Expected output: `ok` + `0.16.0` (or whatever pinned Zig version
v2 uses).

## Phase 0 smoke

The minimum for §9.0 task 0.3 is:

```bash
# from Mac, in zwasm_from_scratch/
rsync -a --delete --exclude=.git --exclude=zig-out --exclude=.zig-cache \
    ./ windowsmini:~/zwasm_from_scratch/

ssh windowsmini "cd zwasm_from_scratch && zig build && zig build test"
```

If both succeed, §9.0 / 0.3 is green.

## Phase 14+ automation

Phase 14 introduces `scripts/run_remote_windows.sh`, which wraps
the rsync + ssh pattern and tees output back to the Mac for
parsing by `gate_merge.sh`. Until then, the smoke is manual.

## Failure modes seen in v1 (avoid in v2)

- **`hyperfine` not on PATH** — installed by `install_tools.ps1`;
  if missing, re-run that script. Tracked in v1 memo.md as the
  C-g step 5 follow-up.
- **`rustup-init` stdout polluting `Install-Rustup`'s return**
  (W53) — fix routes through `Out-Host`. v2 inherits the v1 fix.
- **Bash heredoc differences on Git-bash for Windows** — paths and
  quoting need extra care; use the rsync + ssh pattern instead of
  inline heredoc.

## When to update this file

- After bumping `windowsmini` tool versions, sync the pin list.
- After changing the SSH alias, update the `Host windowsmini` block
  documentation here.
- If Windows verification ever moves to a new host (cloud VM, larger
  mini PC, etc.), this file is the place to record the migration.
