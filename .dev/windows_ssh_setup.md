# Windows SSH (`windowsmini`) Setup

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

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

## `ssh windowsmini cmd /c '...'` — the orchestration short-circuit

**Reach for `cmd /c` first.** windowsmini's default OpenSSH
shell is PowerShell 7. Nesting `bash -lc` re-enters Git-Bash
with MSYS path conversion. Both layers trap on Windows-native
CLI switches (`/F`, `/FI`, `$var` etc) at exactly the wrong
moment. Codified after D-165 cycle 9 debug session (see
[`.dev/lessons/2026-05-23-windowsmini-ssh-quoting-traps.md`](lessons/2026-05-23-windowsmini-ssh-quoting-traps.md)
+ [`.claude/skills/debug_jit_auto/SKILL.md`](../.claude/skills/debug_jit_auto/SKILL.md)
Recipe 15).

```bash
# RELIABLE — cmd interprets Windows switches and paths directly
ssh windowsmini cmd /c "<windows-cmd>"
ssh windowsmini 'cmd /c "cd /d C:\Users\shota\... && git pull && zig build install"'

# OK for bash-style scripts (single-quoted body)
ssh windowsmini bash -lc "'<bash-body>'"

# AVOID — bare PowerShell interpretation of bash-like input
ssh windowsmini '<looks-like-bash-but-runs-in-pwsh>'
```

Use `bash -lc "'...'"` only when you genuinely want
bash/POSIX semantics on Windows (uncommon for debug ops). For
`taskkill`, `tasklist`, `dir`, log paths, lldb attach, etc.
use `cmd /c "..."`.

Log path convention: `%USERPROFILE%\<file>.log` (= `C:\Users\shota\<file>.log`).
`C:\tmp\` does NOT exist by default.

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

## Microsoft Defender exclusions (build-perf)

`MsMpEng.exe` (Defender real-time scan) was observed dominating
CPU during `zig build` on windowsmini, scanning `.zig-cache` /
`zig-out` after every compile. Investing in exclusions
substantially reduces wall-clock time for `test-all` and is also
suspected to reduce the D-028 test-runner-IPC-timeout flake rate.

**Setup procedure** (one-time, from any SSH session — admin
elevation surprisingly *not* required on this windowsmini, so
the standard `shota` SSH user can install these):

```bash
ssh windowsmini 'powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '"'"'C:\Users\shota\Documents\MyProducts\zwasm_from_scratch\.zig-cache'"'"'"'
ssh windowsmini 'powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '"'"'C:\Users\shota\Documents\MyProducts\zwasm_from_scratch\zig-out'"'"'"'
ssh windowsmini 'powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '"'"'C:\Users\shota\AppData\Local\zig'"'"'"'
ssh windowsmini 'powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '"'"'C:\Users\shota\AppData\Local\zwasm-tools'"'"'"'
ssh windowsmini 'powershell -NoProfile -Command "Add-MpPreference -ExclusionProcess '"'"'zig.exe'"'"'"'
```

**Verify** (any time):

```bash
ssh windowsmini 'powershell -NoProfile -Command "Get-MpPreference | Select-Object -Property ExclusionPath, ExclusionProcess | Format-List"'
```

If a fresh windowsmini host is provisioned (or the OS is
reimaged), re-run the setup block above before measuring D-028
recurrence — the absence of Defender exclusions will inflate the
flake-rate baseline.

## Bench mode for windowsmini (§9.8 / 8.3)

The full 26-fixture bench inventory takes 5+ hours on
windowsmini at the observed Mac:Win ~12x ratio (`fib2` alone
takes ~8m24s/run). This is incompatible with the inline
`/continue` loop's gate cadence. The `--windows-subset` flag
on `scripts/run_bench.sh` filters to a 5-fixture fast set
(`shootout/nestedloop` + `tinygo/{arith,fib,sieve,tak}`, all
< 30ms on Linux baseline) that runs in ~6s total on
windowsmini.

Periodic verification on windowsmini:

```bash
ssh windowsmini 'cd Documents/MyProducts/zwasm_from_scratch && \
    bash scripts/run_bench.sh --windows-subset --quick'
```

Or directly on windowsmini in a Git Bash shell:

```bash
cd Documents/MyProducts/zwasm_from_scratch
bash scripts/run_bench.sh --windows-subset
```

Result lands in `bench/results/recent.yaml` (gitignored).
Append to `bench/results/history.yaml` only at phase boundaries
via `--phase-record --reason='<phase-tag>: <gist>'` (rare; the
full 26-fixture baseline remains the canonical record on
Mac/Linux, this subset is for manual periodic regression
checks on Windows).

CI integration with windowsmini is **not** wired (the
`.github/workflows/bench.yml` matrix runs Mac aarch64 + Linux
x86_64 only). SSH-from-Linux-runner CI was considered for
§9.8 / 8.3 but rejected — secret management + cross-network
reliability concerns outweigh the once-per-merge value when
manual periodic verification covers the regression-detection
goal.

## Interactive JIT debug session (windowsmini side, added 2026-05-22)

windowsmini is wired as an **active debug host** equivalent to
Mac aarch64 + ubuntunote x86_64 — not just a passive
phase-boundary gate. The 4-tier iteration workflow
(`.dev/archive/phase9/phase9_13_0_close_plan.md` §0.2.1) covers test-gate
flow; this section covers the **diagnostic flow** when a Win64
JIT bug needs hands-on debugging.

### Prerequisite — `install_tools.ps1 -OnlyTool sysinternals`

The Sysinternals Suite (Procmon, Process Explorer, DebugView,
Handle.exe, ListDLLs, PsExec, etc.) lands at
`%LOCALAPPDATA%\zwasm-tools\sysinternals-<date>\` and joins
User PATH. Run once after a fresh windowsmini provision; bump
via `-Force -OnlyTool sysinternals` when refreshing.

### Windows Defender exclusion baseline

For zwasm v2 workloads on windowsmini, the Defender exclusions
that **must be in place** (per 2026-05-22 user-side
configuration):

**ExclusionPath (8)**:
- `C:\Program Files\LLVM` (lldb + llvm-objdump / nm / readobj / symbolizer / cxxfilt / etc.)
- `C:\Users\shota\AppData\Local\zig` (zig global cache)
- `C:\Users\shota\AppData\Local\zwasm-tools` (wabt / wasmtime / hyperfine / yq / wasm-tools)
- `C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-<date>` (explicit subpath for clarity)
- `C:\Users\shota\AppData\Local\CrashDumps` (reserved for WER `.dmp` output)
- `C:\Users\shota\Documents\MyProducts\zwasm_from_scratch` (repo root)
- `C:\Users\shota\Documents\MyProducts\zwasm_from_scratch\.zig-cache`
- `C:\Users\shota\Documents\MyProducts\zwasm_from_scratch\zig-out`

**ExclusionProcess (17)** — all `build.zig::addExecutable` outputs:
`build.exe`, `test.exe`, `zig.exe`, `zwasm.exe`,
`zwasm-c-host-hello.exe`, `zwasm-edge-runner.exe`,
`zwasm-realworld-{diff,run-jit,run,_}runner.exe` (4),
`zwasm-spec-{assert,runner,simd,wasm-2-0-assert}.exe` (4),
`zwasm-wasi-runner.exe`, `zwasm-wast-runner.exe`,
`zwasm-wast-runtime-runner.exe`.

Verify with:

```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
Get-MpPreference | Select-Object -ExpandProperty ExclusionProcess
```

Without these, D-028-class wedges at runner transitions are
expected (Defender image scan on `*.exe` spawn delays / stalls
the parent's wait). The user 2026-05-22 dialogue captured the
exact PowerShell sequence; future Defender setup drift can be
re-applied from this list.

### SSH-driven debug workflows

The canonical recipes for each debug scenario live in
[`.claude/skills/debug_jit_auto/SKILL.md`](../.claude/skills/debug_jit_auto/SKILL.md)
Recipes 9-14:

| Recipe | Use case | Tool |
|---|---|---|
| 9 | First-triage lldb on a reproducible crash | `lldb` via SSH |
| 10 | D-028 wedge investigation (runner spawn stalls) | `Procmon64.exe` |
| 11 | D-028 hypothesis #3 (fd / handle fullness) | `handle64.exe` |
| 12 | JIT byte stream disasm (Win64 PE/COFF) | `llvm-objdump --disassemble -b binary` |
| 13 | W3.b VEH handler entry trace (post-impl) | `Dbgview.exe` + `OutputDebugStringA` |
| 14 | Post-mortem of WER `.dmp` crash dump | `lldb -c <dump>` |

### Enabling WER crash dump collection (one-time setup, admin required)

`%LOCALAPPDATA%\CrashDumps\` is reserved as the WER drop
location but per-app registration is needed for non-default
collection. **Not yet applied as of 2026-05-22**; apply when
the first Win64 crash needs post-mortem analysis. Snippet (run
as administrator on windowsmini):

```powershell
$reg = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
foreach ($exe in @(
    'zwasm-spec-runner.exe', 'zwasm-spec-assert.exe',
    'zwasm-spec-wasm-2-0-assert.exe', 'zwasm-wast-runner.exe',
    'zwasm-wast-runtime-runner.exe', 'zwasm-realworld-run-runner.exe',
    'zwasm-realworld-run-jit-runner.exe'
)) {
    New-Item -Path "$reg\$exe" -Force | Out-Null
    Set-ItemProperty -Path "$reg\$exe" -Name DumpType -Value 2  # 2 = full mini-dump
    Set-ItemProperty -Path "$reg\$exe" -Name DumpFolder -Value 'C:\Users\shota\AppData\Local\CrashDumps'
    Set-ItemProperty -Path "$reg\$exe" -Name DumpCount -Value 10
}
```

After enable, any unrecovered crash drops a `.dmp` file; use
Recipe 14 (lldb post-mortem) to inspect.

### SSH-vs-desktop trade-off

Procmon / Process Explorer / DebugView have **GUI**, but
their headless invocation (Procmon `/Quiet /BackingFile`,
Dbgview `/g /t /k /l <log>`) works fine over SSH and writes
artifact files we then SCP back. The interactive GUI is
faster for one-off exploration; the SSH form is the
autonomous-loop-friendly path.

## When to update this file

- After bumping `windowsmini` tool versions, sync the pin list.
- After changing the SSH alias, update the `Host windowsmini` block
  documentation here.
- If Windows verification ever moves to a new host (cloud VM, larger
  mini PC, etc.), this file is the place to record the migration.
