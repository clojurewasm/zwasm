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

**W53 done. C-g foundation + Mac/Ubuntu baselines done.** Ship-overnight
session 2026-04-29 evening landed two PRs to main on top of the
afternoon's six (#79..#84):

- **#85** W53 — root-caused the `Cannot bind argument to parameter
  'Path'` failure on a fresh GitHub-hosted Windows runner. Native
  command stdout from `& rustup target add` was being folded into
  `Install-Rustup`'s return value (PowerShell pipeline-output rule),
  turning `$paths['rust']` into a string array; downstream
  `Join-Path $paths['rust'] 'cargo'` exploded on the empty leading
  element. Fix routes both `& $installer` and `& rustup target add`
  through `2>&1 | Out-Host` so the lines surface in the CI log
  without joining the function's pipeline output. Added a
  defensive `[array]` / IsNullOrWhiteSpace check in the caller.
  Dropped `-SkipRust` and the separate `Setup Rust` step from
  `test (windows-latest)`.
- **#86** C-g schema — `bench/history.yaml` is now multi-arch.
  Each entry gains an explicit `arch:` field; all 125 pre-existing
  rows tagged `aarch64-darwin`. `bench/record.sh` auto-detects the
  target triple (override with `--arch=...`), and the duplicate-id
  check is now scoped by `(id, arch)` so two triples can both
  record an entry against the same merge SHA.
  `scripts/record-merge-bench.sh` dropped the Darwin-only guard
  and now passes the auto-detected `--arch=...` through.
  `.claude/CLAUDE.md` Merge-Gate item 10 reworded to match.

Post-merge bench rows for the C-g merge (`e5766ee`):

- `aarch64-darwin` — native M4 Pro, hyperfine 1.19.0.
- `x86_64-linux` — OrbStack `my-ubuntu-amd64` (Rosetta-translated;
  treat as schema-shakedown baseline only, not a native x86_64
  reference).

## Open work

### 0. **W54** — close the 2.1× wasmtime gap on `tgo_strops`

`bench/runtime_comparison.yaml` (2026-03-25, commit 65db814,
runs=1/warmup=0) shows zwasm cached 63.2 ms vs wasmtime cached
30.0 ms on `tgo_strops`. Current main (`448f4c8`) is ~67 ms
cached, so the gap is structural — and it dwarfs the W47 +15 %
post-0.16 regression. Bigger leverage than W47.

Hot loop is TinyGo's `digitCount` — `i32.div_u 10 + br_if` inside
`for v > 0`. The lever is the constant-divisor optimisation that
cranelift does by default. Strategy stack (single-pass-compatible,
ordered by leverage):

1. **Constant-divisor → multiply-high in predecode**. Two-op
   window peephole for `i32.const K; i32.div_u` (and `rem_u`,
   `mul K` power-of-two). Synthesise `udiv_const K`; JIT emits
   `UMULH + LSR` on ARM64, `MUL + SHR` on x86_64. Magic
   numbers pre-computed per K. UDIV ~10 cyc → UMULH ~3 cyc,
   so realistic gain ≈ wasmtime parity for div-heavy workloads.
2. **Loop-header Q-cache persistence (W45)**. Skip Q-cache
   evict at loop headers so induction vars stay in registers.
   Already designed.
3. **`br_if` fall-through audit**. Confirm `regalloc.zig`
   places the fall-through arm as the loop-continuation path.
4. **Interpreter dispatch codegen diff** (also closes W47).
   asm diff `vm.zig` hot dispatch v1.9.1 vs main under
   Zig 0.16 / LLVM 19.

Out of scope (would break single-pass): SSA, global regalloc,
auto unroll / vectorise. Re-record `runtime_comparison.yaml` at
5 runs / 3 warmup before claiming a win — current values are
single-sample. Detailed strategy in `.dev/checklist.md` W54.

### 1. **W47** — `tgo_strops_cached` regression with stable harness

Investigation in `.dev/w47-investigation.md` is intact:

- Real signal: ~15 % uniform slowdown on both cached and uncached
  variants (the original "+24 % cached only" framing was a 5-run
  sample artifact).
- Variance: σ ≈ 18 % of the mean for this benchmark. Bisect needs
  σ < 5 %.
- Suspect range: v1.9.1 (`078f8f2`) → v1.10.0 (`c89b95a`), which
  is the Zig 0.15 → 0.16 + W46 link_libc window.

Stabilise the harness first — 50 run hyperfine alone reduces
σ_mean by only sqrt(2.5) ≈ 1.6×, so likely needs an in-process
loop that subtracts module load + WASI startup from each sample
to actually drop σ under 5 %. Then bisect.

### 2. **C-g step 5** — flip the `benchmark` CI job to a 3-OS matrix

The schema work in #86 unblocks the matrix flip. Outstanding
pieces:

- Pin `hyperfine` in `.github/versions.lock` and add a Windows
  install path in `scripts/windows/install-tools.ps1` (it already
  fetches binaryen from a similar GitHub release artifact, so the
  shape is straightforward).
- `ci.yml` `benchmark` job: drop `runs-on: ubuntu-latest`, switch
  to a `os: [ubuntu-latest, macos-latest, windows-latest]` matrix.
  Mac uses the test-nix devshell hyperfine; Linux keeps the .deb
  install (or also flips to nix); Windows uses the new
  `install-tools.ps1` path.
- Collect a **native** x86_64-linux baseline. The current
  `e5766ee/x86_64-linux` row is OrbStack-Rosetta — useful for
  schema validation, not for cross-platform regression analysis.
  Easiest path: a one-shot CI workflow_dispatch that runs
  `record-merge-bench.sh --arch=x86_64-linux` on a GitHub-hosted
  ubuntu-latest runner and uploads the diff as a PR.

Once those land, the `benchmark` job can be the same on all three
OSes and the W47 triage gets cross-platform data for free.

### 3. **C-g step 5 prerequisite** — Windows hyperfine baseline

`windowsmini` SSH host is available but does not have hyperfine
on PATH. After C-g step 5's hyperfine pin in `install-tools.ps1`,
re-run `pwsh install-tools.ps1` there and then
`bash scripts/record-merge-bench.sh` to add the Windows baseline.

## Quick orient on session start

```bash
git log --oneline origin/main -10        # confirm what's on main
git status --short                       # any unstaged carry-over from prior session?
cat .dev/checklist.md                    # W47 / C-g step 5 are the open items
bash scripts/sync-versions.sh            # toolchain pin sanity (instant)
bash scripts/gate-commit.sh --only=tests # smoke test
```

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
