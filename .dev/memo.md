# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Zig toolchain**: 0.16.0 (migrated 2026-04-24).
- Stages 0-47 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, 20 complete.
- Spec: 62,263/62,263 Mac+Ubuntu+Windows CI (100.0%, 0 skip).
- E2E: 796/796 Mac+Ubuntu+Windows CI, 0 fail.
- Real-world: Mac 50/50, Ubuntu 50/50, Windows 25/25 (C+C++ subset; Go/
  Rust/TinyGo provisioning on Windows tracked as W52). 0 crash.
- FFI: 80/80 Mac+Ubuntu.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary stripped: Mac 1.20 MB, Linux 1.56 MB (ceiling 1.60 MB; tightened from 1.80 MB in W48 Phase 1). Memory: ~3.5 MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. v1.10.0 released; post-release work on delib / W46 merged
  via PRs #47 (1a/1b pre-cursor), #48 (1b), #49 (1c/1d/1e/1f + C-API libc fix).
- link_libc = false across lib / cli / tests / examples / e2e / bench / fuzz.
  C-API targets (shared-lib, static-lib, c-test) keep link_libc = true because
  `src/c_api.zig` uses `std.heap.c_allocator`.

## Current Task

**Plan C done. Plan B sub-3 (W50) done. W47 investigated.**
Session 2026-04-29 PM landed six PRs to main on top of the morning's
seven (#68..#74):

- **#79** docs+ci trailing cleanup (memo.md / CHANGELOG / nightly.yml
  drift after #75..#78).
- **#80** W50 PR-A — `flake.nix` explicit URL+sha256 pins for
  wasm-tools 1.246.1 + wasmtime 42.0.1.
- **#81** W50 PR-B — new `test-nix (ubuntu-latest)` job using
  Nix devshell + gate-commit.
- **#82** W50 PR-C — `test-nix` matrix extended to macOS.
- **#83** W50 PR-D — Windows test switched to `install-tools.ps1
  -SkipRust` + `gate-commit.sh`. Added binaryen 125 to
  install-tools.ps1, restored extras (c-test / static-lib /
  static-link / Rust example / memory check) on all 3 OSes,
  reordered cargo run before static-lib build (Windows
  `zwasm.lib` collision).
- **#84** W47 investigation note — 20-run remeasurement showed
  variance dominates the +24% signal; `.dev/w47-investigation.md`
  records the findings + next-step recommendations.

Per-merge `bench/history.yaml` rows recorded on Mac M4 Pro for
each of #68..#84.

## Open work, in recommended order

The 2026-04-29 PM session left three items sequenced. Each builds
on the previous; do them in order.

### 1. **W53** — fix the `install-tools.ps1` rust install path bug

CI currently bypasses it with `-SkipRust`. Local Windows
mini-PC is fine. Repro: a fresh GitHub-hosted Windows runner
calling `pwsh install-tools.ps1` (without `-SkipRust`). Symptom:

```
info: downloading component rust-std
install-tools.ps1: Cannot bind argument to parameter 'Path' because it is an empty string.
```

Suspects: `Install-Rustup` line 296 (`& $installer ...`) or 303
(`& (Join-Path $cargoHome 'bin\rustup.exe') target add
wasm32-wasip1`). Approach: enable `Set-StrictMode -Version Latest`
+ `$ErrorActionPreference = 'Stop'` at the top of install-tools.ps1
to surface a stack trace, then re-run on a temporary CI branch.
Once root-caused, drop `-SkipRust` from `ci.yml` `test
(windows-latest)` and verify Windows CI still goes green.

`.dev/checklist.md` W53 has the full notes.

### 2. **C-g** — 3-platform bench baseline reset

Now that W50 finished, all three CI runners (Mac / Ubuntu / Windows)
use the same flake-pinned toolchain. Time to actually compare
absolute bench numbers across platforms (the user specifically
suspected "Windows だけやたら性能劣化" might exist).

Sequence:

1. `bench/history.yaml` schema: add `arch:` field to each entry
   (default `aarch64-darwin` — that's all current rows). Allow
   per-entry `env:` override of `cpu` / `os`.
2. `scripts/record-merge-bench.sh`: drop the "Darwin only" early
   exit; per-arch series are independent.
3. Cleanroom baseline collection:
   - Mac M4 Pro local — `bash scripts/record-merge-bench.sh`
   - Ubuntu via OrbStack `my-ubuntu-amd64` — same command
   - Windows via SSH `windowsmini` — same command (uses
     `install-tools.ps1` toolchain, hyperfine should be on PATH
     after binaryen install added it). One row each, tagged with
     `arch`.
4. `bench/ci_compare.sh`: already self-contained per-runner (does
   fresh measure of base vs PR on the same host); confirm no per-arch
   filtering changes needed.
5. After (1)-(4) ship and the 3 baselines are recorded, drop the
   Ubuntu-only guard on the `benchmark` CI job in `ci.yml` and let
   it run as a 3-OS matrix. That formally closes Plan C-g.

Roughly one supervised PR + ~10 min of bench collection per
platform. Foundation for W47.

### 3. **W47** — `tgo_strops_cached` regression with stable harness

Investigation already in `.dev/w47-investigation.md`:

- Real signal: ~15 % uniform slowdown on both cached and uncached
  variants (the original "+24% cached only" framing was a 5-run
  sample artifact).
- Variance: σ ≈ 18 % of the mean for this benchmark. Bisect needs
  σ < 5 %.
- Suspect range: v1.9.1 (`078f8f2`) → v1.10.0 (`c89b95a`), which
  is the Zig 0.15 → 0.16 + W46 link_libc window.

After C-g lands the per-arch data, also compare across Mac /
Ubuntu / Windows: is the regression Mac-only (ARM64 JIT
codegen), Mac+Ubuntu (cross-platform JIT path), or all-platform
(interpreter dispatch)? That triages the bisect range immediately.

Stabilise the harness first (50-run hyperfine or in-process JIT
timing that subtracts module load + WASI startup), then bisect.

## Quick orient on session start

```bash
git log --oneline origin/main -10        # confirm what's on main
git status --short                       # any unstaged carry-over from prior session?
cat .dev/checklist.md                    # W53 / C-g / W47 are the open items
bash scripts/sync-versions.sh            # toolchain pin sanity (instant)
bash scripts/gate-commit.sh --only=tests # smoke test
```

`.dev/resume-guide.md` was deleted at the end of the 2026-04-29 PM
session because Plan B sub-3 + Plan C are done; this "Current Task"
block is the only handover document going forward.

## Previous Task

**Overnight 2026-04-28 → 2026-04-29.** Seven PRs to main:

- #60 — `flake.nix` made SSoT, `versions.lock` mirror, WASI SDK 25→30,
  D136 in decisions.md, `.dev/environment.md` initial.
- #61 — `scripts/gate-commit.sh`, `gate-merge.sh`, `run-bench.sh`,
  `sync-versions.sh`, `lib/versions.sh`, `windows/install-tools.ps1`.
- #62 — CI `versions-lock-sync` job (Merge Gate item #9 mechanised).
- #64 — Windows memory check via PowerShell (1 of 8 Windows guards down).
- #65 — `HYPERFINE_VERSION` sourced from versions.lock.
- #66 — `.dev/resume-guide.md` + W49-W52 in checklist.md +
  CHANGELOG `[Unreleased]` capture.
- #67 — doc-drift sweep (E2E count 792→796, Stages 0-46→0-47, real-world
  scope clarified, Zig 0.15.2 / WASI SDK 25 / wasm-tools 1.245.1
  references bumped, `bash scripts/gate-commit.sh` promoted in
  contributing guides). W51 resolved.

Pre-overnight: **W48 Phase 1 — DONE (2026-04-25).** Trimmed Linux
binary 1.64 → 1.56 MB (-83 KB) and Mac 1.38 → 1.20 MB (-180 KB) via
three changes in `src/cli.zig`: `pub const panic =
std.debug.simple_panic`, `std_options.enable_segfault_handler = false`
(zwasm has its own SIGSEGV handler), and `main` returning `u8` instead
of `!void`. Remaining 62 KB to target 1.50 MB (W48 Phase 2,
non-blocking — `std.Io.Threaded` ~115 KB and `debug.*` 81 KB are the
biggest contributors; lever is `std_options_debug_io` override with a
minimal direct-stderr Io instance).

**W46 Phase 2 — DONE (2026-04-25 via PR #52).** Routed remaining
`std.c.*` direct calls in `wasi.zig` through `platform.zig` helpers.
Size-neutral on Linux because the `std.c.*` sites were already inside
comptime-pruned `else` arms; pure consistency refactor.

### W46 earlier phases

**W46 Phase 1c/1d/1e/1f — DONE (2026-04-25 via PR #49).**

Routed test-site and trace-site `std.c.*` calls through new platform helpers
(`pfdDup2`, `pfdPipe`, `pfdSleepNs` added alongside existing `pfd*` family),
then flipped `.link_libc = false` across every module in `build.zig` except
the three C-API targets. CI-green on all four runners (Mac/Ubuntu/Windows/
size-matrix). Fix commit `c11a947` routed `std.c.{pipe,dup,dup2,read,
nanosleep}` in wasi.zig+vm.zig tests; `04ac19d` kept link_libc=true on
C-API targets after the first push revealed `std.heap.c_allocator` needs libc.

### Hard-won nuggets (reuse later)

- **Do NOT wrap in `nix develop --command` inside this repo.** direnv +
  claude-direnv has already loaded the flake devshell AND unset
  DEVELOPER_DIR/SDKROOT. Re-entering nix shell re-sets SDKROOT and breaks
  `/usr/bin/git`. See `memory/nix_devshell_tools.md`.
- **e2e_runner uses `init.io`, NOT a locally constructed Threaded io**.
  A fresh `std.Io.Threaded.init(allocator, .{}).io()` inside user main
  crashes with `0xaa…` in `Io.Timestamp.now` when iterating many files.
- **C-API targets must keep `link_libc = true`.** `src/c_api.zig` uses
  `std.heap.c_allocator`. Mac masks this via libSystem auto-link; Linux and
  Windows fail with "C allocator is only available when linking against libc".
- **Cross-compile sanity trick.** `zig build test -Dtarget=x86_64-linux-gnu`
  and `-Dtarget=x86_64-windows-gnu` compile cleanly on Mac even though the
  test binaries can't execute — the compile success alone catches link-time
  symbol-resolution issues before pushing to CI.
- **Linux is already libc-free even when `std.c.*` appears in source.**
  Inside a `switch (comptime builtin.os.tag)`, the `.linux =>` and
  `else =>` arms are comptime-pruned; the Linux build never references
  `std.c.*` bindings even if they appear textually. This is why W46 Phase 2
  was size-neutral on Linux — the refactor only cleans up Mac/BSD code
  paths.

## References

- `@./.dev/roadmap.md` — phase roadmap + long-term direction
- `@./.dev/checklist.md` — open work items (W##) + resolved summary
- `@./.dev/decisions.md` — architectural decisions (D100+)
- `@./.dev/references/ubuntu-testing-guide.md` — OrbStack-driven Ubuntu gates
- External impls to cross-read when debugging / designing:
  `~/Documents/OSS/wasmtime/` (cranelift codegen), `~/Documents/OSS/zware/`
  (Zig idioms).
