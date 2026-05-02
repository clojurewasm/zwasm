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

- Git for Windows (supplies bash + curl + tar + unzip + ssh client)
- PowerShell 7
- Python 3.x
- winget
- The pinned tools (`zig`, `wasm-tools`, `wasmtime`, WASI SDK,
  `hyperfine`) — for Phase 0 the user's existing zwasm v1 install
  on `windowsmini` (its `scripts/windows/install-tools.ps1`)
  satisfies this. zwasm v2 wires its own `scripts/windows/`
  installer at Phase 14+.

`rsync` is **not** required on `windowsmini`; v2 syncs via
`git pull` from `origin`, mirroring zwasm v1.

## SSH alias

The Mac's `~/.ssh/config` should already have:

```
Host windowsmini
    HostName <ip-or-hostname>
    User <user>
    IdentityFile ~/.ssh/<keyfile>
```

`windowsmini`'s default OpenSSH shell is PowerShell, so wrap any
shell-script body with `bash -lc '...'` when invoking via `ssh`.

Verification:

```bash
ssh windowsmini "echo ok && zig version"
```

Expected output: `ok` + `0.16.0` (or whatever pinned Zig version
v2 uses).

## Bootstrap (one-time, per host)

The clone lives at the same path as v1's: `~/Documents/MyProducts/`.
Only the directory name differs.

```bash
ssh windowsmini bash -lc "'
  mkdir -p ~/Documents/MyProducts &&
  cd ~/Documents/MyProducts &&
  git clone -b zwasm-from-scratch git@github.com:clojurewasm/zwasm.git zwasm_from_scratch
'"
```

`origin` ends up pointing at the same `clojurewasm/zwasm` GitHub
remote that v1 uses; the `zwasm-from-scratch` branch is the
long-lived v2 branch.

## Phase 0 smoke

The minimum for §9.0 task 0.3 is:

```bash
# from Mac, in zwasm_from_scratch/
ssh windowsmini bash -lc "'
  cd Documents/MyProducts/zwasm_from_scratch &&
  git fetch origin zwasm-from-scratch &&
  git reset --hard origin/zwasm-from-scratch &&
  zig build &&
  zig build test
'"
```

If both succeed, §9.0 / 0.3 (and the test half of 0.5) is green.

## Day-to-day sync

`scripts/run_remote_windows.sh` wraps the same pattern:

```bash
bash scripts/run_remote_windows.sh build      # zig build
bash scripts/run_remote_windows.sh test       # zig build test
bash scripts/run_remote_windows.sh test-all   # zig build test-all (default)
```

Each invocation `git fetch + git reset --hard origin/zwasm-from-scratch`
on the remote and then runs the requested step. **It tests the
latest pushed state on origin**, so commit-and-push first if you
need the local change to land in the gate.

This script is what `scripts/gate_merge.sh` calls when verifying
the windowsmini half of the three-OS gate.

## Phase 15+ extension

Phase 15 may add a `git bundle` path so unpushed commits can also
be exercised on `windowsmini` (useful for pre-push gates). Until
then, `git pull` against `origin` is the source of truth — same as
zwasm v1.

## Failure modes seen in v1 (avoid in v2)

- **`hyperfine` not on PATH** — installed by `install_tools.ps1`;
  if missing, re-run that script. Tracked in v1 memo.md as the
  C-g step 5 follow-up.
- **`rustup-init` stdout polluting `Install-Rustup`'s return**
  (W53) — fix routes through `Out-Host`. v2 inherits the v1 fix.
- **Bash heredoc differences on Git-bash for Windows** — paths and
  quoting need extra care; use `bash -lc '...'` over inline
  heredocs.

## When to update this file

- After bumping `windowsmini` tool versions, sync the pin list.
- After changing the SSH alias, update the `Host windowsmini` block
  documentation here.
- If Windows verification ever moves to a new host (cloud VM, larger
  mini PC, etc.), this file is the place to record the migration.
