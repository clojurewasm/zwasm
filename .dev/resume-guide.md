# Session Resumption Guide

Read this when a new session opens with no context and the user asks
to continue (in any language; common phrasings include "continue",
"keep going", or the same intent expressed in Japanese). This
document plus `git log --oneline -10` is intended to give you
everything you need to make safe forward progress without re-reading
the prior chat.

The guide is **evergreen** — update it as work lands. Pointer from
`.dev/memo.md` `## Current Task` should always lead here while there
is residual Plan C / Plan B sub-3 work; remove the pointer once those
are exhausted.

## Where main is (snapshot 2026-04-29)

Seven PRs landed overnight 2026-04-28 → 2026-04-29:

| PR  | Title                                                      | Effect                                                |
|-----|------------------------------------------------------------|-------------------------------------------------------|
| #60 | feat(env): Nix-mirror versions.lock + WASI SDK 30 + environment.md | `flake.nix` becomes SSoT; `.github/versions.lock` mirrors it for Windows / non-Nix consumers; WASI SDK bumped 25→30. D136 records the design. |
| #61 | feat(scripts): unified gate runners + Windows installer    | `scripts/gate-commit.sh`, `gate-merge.sh`, `run-bench.sh`, `sync-versions.sh`, `lib/versions.sh`, `windows/install-tools.ps1`. CLAUDE.md gates point at the runners. |
| #62 | ci: enforce versions.lock ↔ flake.nix consistency          | New `versions-lock-sync` job in ci.yml runs `scripts/sync-versions.sh` on every PR. |
| #64 | ci: add Windows memory usage check via PowerShell          | First of the eight Windows-skip CI guards removed. PowerShell measures `Process.PeakWorkingSet64` against the 4.5 MB budget. |
| #65 | ci: source HYPERFINE_VERSION from versions.lock            | Pinning consistency. No behaviour change at the same version. |
| #66 | docs(handoff): resume-guide.md + W49-W52 + CHANGELOG       | This document established. W49 (Plan C residuals), W50 (CI Nix-ify), W51 (doc drift), W52 (Windows realworld toolchain) recorded; CHANGELOG `[Unreleased]` block populated for the next `/release`. |
| #67 | docs: cleanup sweep                                        | E2E count 792 → 796, Stages 0-46 → 0-47, real-world platform scope clarified (Mac+Ubuntu 50/50, Windows 25/25 C+C++ subset), stale 0.15.2 / WASI SDK 25 / wasm-tools 1.245.1 references bumped, `bash scripts/gate-commit.sh` promoted in CONTRIBUTING.md and book contributing guides. W51 resolved. |

Verified working state on **2026-04-29** (do **not** trust this list past
about a week — re-verify by reading current code):

- `bash scripts/gate-commit.sh` returns green on macOS aarch64 (6/6) and
  Windows x86_64 (5/5; `ffi` host-skipped to mirror CI).
- `bash scripts/sync-versions.sh` exits 0 (Zig 0.16.0, WASI SDK 30 match).
- Windows toolchain installs cleanly via
  `pwsh scripts/windows/install-tools.ps1` from a fresh checkout
  (provisions Zig + wasm-tools + wasmtime + WASI SDK + VC++ Redist).
- Realworld on Windows: 25/25 PASS for the C+C++ subset (Go/Rust/TinyGo
  not yet provisioned by the installer; SKIP gracefully).

## Hard-won facts (not obvious from the code)

These bit me overnight; future sessions will hit the same things if
they don't read them.

1. **Microsoft Store python alias trap.** A blank Windows 11 has
   `python.exe` as a 0-byte App Execution Alias that opens the Store
   when invoked headlessly. `python --version` prints `Python ` (no
   number) and exits. Real Python must be installed (winget
   `Python.Python.3.14` or python.org installer) before
   `install-tools.ps1` can do anything useful.
2. **Git for Windows does not put `bash` on PATH** by default. Add
   `C:\Program Files\Git\bin` to user PATH (the installer does this
   automatically; if missing, see install-tools.ps1's tail).
3. **WASI SDK 30 clang.exe needs Microsoft Visual C++ Redistributable.**
   Stock Windows 11 carries only the .NET-flavoured
   `vcruntime140_clr0400.dll`; the plain runtime is missing.
   `install-tools.ps1` runs `winget install Microsoft.VCRedist.2015+.x64`
   automatically.
4. **wasm-tools Windows asset is `.zip`, not `.tar.gz`.**
   bytecodealliance ships zip for Windows but tar.gz for Linux/macOS.
5. **wasmtime Windows release zip has no `bin/` subdirectory** — the
   `.exe` lives directly in the extracted folder. Linux/macOS tarballs
   do have `bin/`.
6. **`.github/versions.lock` has a no-inline-comment policy.** Bash
   `source` strips trailing `# …`, but the Python reader at
   `ci.yml > Install WASI SDK (Windows)` uses `split('=', 1)` and the
   comment ends up in the URL. The file header documents this and the
   Python reader now defensively strips `#`.
7. **Admin SSH on Windows uses
   `C:\ProgramData\ssh\administrators_authorized_keys`**, not the
   user's `~/.ssh/authorized_keys`. Permissions must be exactly
   `Administrators:F` + `SYSTEM:F`; sshd silently ignores looser perms.
8. **`zig objcopy --strip-all` is ELF-only.** It refuses Mach-O with
   `InvalidElfMagic`. Any cross-platform "size after strip" rewrite
   needs a different mechanism (build.zig `-Dstrip=true`, or per-OS
   tooling). This is why C-e below is non-trivial.
9. **The `failed command:` line in `zig build test` output is harmless.**
   It is Zig 0.16's stderr per-seed footer for fuzz-test discovery; the
   build process exit code is still 0. Don't grep for that string.
10. **autonomous merge authorisation expires per session.** See
    `~/.claude/projects/.../memory/autonomous_mode_permission.md`.
    Without an explicit "I'm going to sleep, get this done by morning"
    grant for the **current** session, default to "open PR, request
    review" — never merge to main.

## Outstanding work — pick from these

The user is comfortable with stacking small PRs. Each item below is
self-contained and reversible. Do **not** attempt all of them in one
session; pick the smallest unblocking subset first.

### Plan C — remove remaining Windows-skip CI guards

`ci.yml` still carries seven `if: runner.os != 'Windows'` (or
equivalent) guards. None reflects a fundamental incompatibility — every
one is shell-script or C-side limitation. See `.dev/environment.md` for
the full table; ordered here by safety / value.

| Id  | Guard                                       | Work                                                                                          | Risk   |
|-----|---------------------------------------------|-----------------------------------------------------------------------------------------------|--------|
| C-d | `zig build static-lib` + static link tests  | Replace `cc` with `zig cc` in `test/c_api/run_static_link_test.sh`; branch on `RUNNER_OS`.    | Low    |
| C-c | `examples/rust` `cargo run`                 | Add Windows arm to `examples/rust/build.rs` for the dynamic library lookup; remove guard.     | Medium |
| C-e | Binary size check (uses GNU `strip`)        | Expose `-Dstrip=true` in build.zig; CI does `zig build -Dstrip=true -Doptimize=ReleaseSafe` and reads the binary directly. ELF/Mach-O/PE all handled by the Zig toolchain. | Medium |
| C-f | `size-matrix` Ubuntu-only                   | Depends on C-e. Convert to OS matrix once stripping is portable.                              | Small  |
| C-b | `test/c_api/run_ffi_test.sh`                | Port `test/c_api/test_ffi.c` to use `LoadLibraryA` + `GetProcAddress` on Windows; `.dll` path branch in the shell script. ~50 lines C + 10 lines shell. | High   |
| C-g | `benchmark` Ubuntu-only                     | hyperfine Windows zip install + `bench/ci_compare.sh` GNU dependency audit (`/usr/bin/time`, `awk`, `comm`). Likely invasive. | High   |

Suggested order: **C-d → C-e → C-f → C-c → C-b → C-g**. (C-a landed
post-2026-04-29 — `zig build shared-lib` on Windows produces
`zwasm.dll` + `zwasm.lib` natively from
`addLibrary({.linkage = .dynamic})`; guard was a no-op.)

After each removal: check `gate-commit.sh` no longer needs the
matching auto-skip in `scripts/gate-commit.sh:case "$HOST_KIND"`.

### Plan B sub-3 — CI Nix-ify (deferred from overnight)

| Id   | Work                                                                                                          | Risk   |
|------|---------------------------------------------------------------------------------------------------------------|--------|
| B3-a | Linux/macOS `test` job → `DeterminateSystems/nix-installer-action` + `magic-nix-cache-action` + `nix develop --command bash scripts/gate-commit.sh`. | Medium |
| B3-b | Windows `test` job → `pwsh scripts/windows/install-tools.ps1` then `bash scripts/gate-commit.sh`.             | Medium |
| B3-c | `nightly.yml` mirrored to the same shape.                                                                     | Small  |
| B3-d | `flake.nix` extension: explicit pins for wasm-tools / wasmtime / hyperfine (URL + sha256), no longer nixpkgs-derived. | Medium |

Reason this was deferred: ci.yml restructure is large; magic-nix-cache
had a 2025 outage; macos-latest + nix-installer-action has occasional
CI flakes. Best done in a single PR with the user watching, not
overnight.

### realworld coverage on Windows (W52)

`install-tools.ps1` provisions Zig + wasm-tools + wasmtime + WASI SDK
only. `build_all.py` SKIPs Go / Rust / TinyGo when those toolchains
are missing, so the Windows realworld run is 25/25 (C + C++ only)
instead of 50/50. To close: extend `install-tools.ps1` (or split off
a follow-on `install-extras.ps1`) with rustup-init + Go + TinyGo,
each pinned via `versions.lock`. Filed as W52 in `.dev/checklist.md`.

The 2026-04-29 doc-drift sweep (W51) already brought README,
contributing guides, setup-orbstack.md, roadmap.md, and book getting-
started.md into sync with the current pins and metrics; nothing
left to do for that bucket.

## When to cut a release

`v1.11.0` is the most recent tag. The PRs merged overnight are
infrastructure / developer-tooling changes; **no public API or
behavioural change for embedders**. By strict semver this is a patch
bump (v1.11.1).

Cut a release when one of these is true:

- A user-facing feature lands (new CLI flag, new public function).
- A behaviour change matters (perf regression resolved, bug-fix the
  user can ask "is this in a tag yet").
- The user explicitly asks for a tag.
- ClojureWasm (downstream) wants a stable pin instead of `main`.

The `/release` skill automates the tag, `CHANGELOG.md` finalisation,
benchmark recording, and the ClojureWasm pin update. Do **not** cut a
tag manually — let the skill handle it.

Keep the `## [Unreleased]` block in `CHANGELOG.md` current as PRs
merge so `/release` can roll up. Append entries as you ship.

A new session **does not** cut a release on its own initiative.
Releases are user-triggered (`/release`).

## ClojureWasm propagation

CW depends on zwasm `main` via the GitHub URL pin. So:

- **Routine main merges** automatically reach CW on the next CW build.
  No explicit propagation step.
- **Behaviour changes** that could affect CW (interpreter / wasi / GC
  semantics) need a CW regression check. The `/release` skill exercises
  CW's test suite against the new tag; for bare-main changes, run CW's
  Mac+Ubuntu tests manually before assuming green.
- **Windows-only work in zwasm** does **not** require CW changes.
  CW's documentation does not claim Windows support and CW's CI matrix
  is Mac+Ubuntu only. Plan C and B3 work is therefore CW-neutral.

If a Windows-driven debug session uncovers a real interpreter / WASI
bug (i.e. the zwasm core, not the script wrappers), treat it as a
universal bug — fix in zwasm proper, exercise CW's tests, and
re-verify on Mac+Ubuntu before merging. **Do not** hide the bug behind
a Windows guard.

## Procedural rules (override session defaults)

- **No-Workaround Rule (CLAUDE.md).** A Windows-specific failure
  during Plan C is a **bug discovery, not a setback**. The whole
  point of buying the Windows mini-PC was to surface these bugs.
  Add a `W##` entry, fix the root cause in zwasm proper, re-verify
  on Mac+Ubuntu (CW regression surface), then remove the CI guard.
  Do **not** paper over with `if: runner.os != 'Windows'`.
- **Autonomous merge authorization is per-session.** Without an
  explicit grant from the user in the **current** session, the
  default is: push to a feature branch, open the PR, wait for the
  user to merge. Two recognised grant intents (the user may express
  either in English or Japanese):
  - **Doc-only fast-track** ("merge without waiting for CI") —
    `gh pr merge` is allowed immediately after push for PRs whose
    diff is documentation only or single-line config only. **Still
    run `bash scripts/sync-versions.sh` locally before merging.**
  - **Ship-overnight** ("merge for me / I'm going to bed / get this
    done by morning") — broad authority for the rest of the session,
    including substantive code, but only when every Merge Gate item
    passes (including the local Mac bench record). Open PR if any
    uncertainty remains.
- **Stack PRs sparingly.** A second PR stacked on a first is fine
  when the work is genuinely incremental and the first is reviewable
  in isolation. If they share commits, the squash-merge of the first
  closes the second's PR (because GitHub deletes the source branch);
  then re-open as a fresh PR with a forced rebase. (Hit this with
  PR #63 → #64 overnight.)
- **Prefer `gh pr merge --squash --delete-branch`** for these
  feature branches; the project history stays linear.
- **`gh pr rerun --failed`** is the right move for transient
  ETIMEDOUT / setup-zig flakes (saw one on #65 post-merge); never
  push a no-op commit just to retrigger.

## How to use this guide on resume

The expected entry point is the user asking the session to continue
(any language) on a fresh session that has no context other than
this repo. The session's first move is the CLAUDE.md Orient step,
which lands here via `.dev/memo.md ## Current Task`.

1. **Sync local main first.** `git checkout main && git fetch origin
   && git pull --ff-only origin main`. Your local main may be many
   merges behind — Orient does not pull on its own.
2. **Sanity checks** (each is fast — under 30 s):
   - `bash scripts/sync-versions.sh` — versions.lock ↔ flake.nix.
   - `bash scripts/gate-commit.sh --only=tests` — Zig build + unit tests.
3. **Pick one item** from "Outstanding work" above. Smallest first;
   the table is ordered by ascending risk within each area.
4. **Branch.** `git checkout -b develop/<short-task-name>`.
   Conventional names for the residual work:
   `develop/ci-windows-shared-lib`,
   `develop/ci-windows-static-lib`,
   `develop/ci-windows-strip-cross-platform`,
   `develop/ci-windows-rust-ffi-example`,
   `develop/ci-windows-test-ffi-c-port`,
   `develop/ci-nix-installer`, etc.
5. **Implement.** Edit, then locally `bash scripts/gate-commit.sh`
   (full gate ~6 min on Mac). For Windows-only changes, also verify
   via SSH on the user's local Windows mini-PC (only available on
   shota's machine — `~/.ssh/config` carries a `windowsmini` entry):
   ```bash
   ssh windowsmini 'cd C:/Users/shota/Documents/MyProducts/zwasm \
       && git fetch origin develop/<branch> \
       && git checkout develop/<branch> \
       && git reset --hard origin/develop/<branch> \
       && bash scripts/gate-commit.sh'
   ```
   If the branch bumped a tool version in `versions.lock`, re-run
   `pwsh scripts/windows/install-tools.ps1` on the Windows side first.
   It is idempotent and only re-installs on version mismatch; pass
   `--Force` to refresh anyway.
6. **Push, PR.** `git push -u origin develop/<branch>`, then
   `gh pr create --base main`. Watch CI via `Monitor` (do not poll).
   Do not stack more than one open PR per session unless the user has
   explicitly granted "ship a stack overnight" autonomy.
7. **Merge.** Default behaviour is "wait for the user to merge". If
   the user has said "merge without waiting for CI" for a doc-only
   change, or "ship overnight" for substantive work, use
   `gh pr merge <N> --squash --delete-branch`. See
   `memory/autonomous_mode_permission.md` for the scope rules.
8. **Post-merge bench record (Mac only, every merge).**
   ```bash
   git checkout main && git pull --ff-only
   bash scripts/record-merge-bench.sh           # always full, ~5 min
   git add bench/history.yaml
   git commit -m "Record benchmark for <PR subject>"
   git push origin main
   ```
   The script auto-derives `--id` from the merge SHA and `--reason`
   from the commit subject, and is a no-op on Linux/Windows
   (`bench/history.yaml`'s `env:` block is Darwin-only). **Always full
   hyperfine (5 runs + 3 warmup).** Lower counts produce noisy /
   cold-cache-biased numbers and are reserved for
   `bench/run_bench.sh --quick`'s interactive smoke tests. The
   per-merge history is the canonical Mac M4 Pro absolute-time
   baseline used at tag time — every row must be measurement-grade.
9. **Refresh this guide.** When an item lands, delete its row from
   the relevant table.
10. **Tear down when done.** When the Plan C and Plan B sub-3
    sections empty out, delete `.dev/resume-guide.md` and the
    pointer block in `.dev/memo.md ## Current Task`.

## Stop conditions

Stop and wait for the user (do **not** push speculative fixes) if:

- A Plan C item turns out to be deeper than the table estimates
  (Windows-only zwasm behaviour bug, build.zig structural change
  beyond expectation).
- CI fails twice on the same PR for non-flaky reasons.
- Any change risks affecting non-Windows behaviour (CW regression
  surface).
- A merge to main would race ahead of an in-flight user-facing PR.

In all of these: leave a clearly-titled draft PR with a body that
quotes the failure and what you tried. The user can pick it up.
