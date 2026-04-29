# Deferred Work Checklist

Open items only. Resolved items in git history.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open Items

- [ ] W49: Plan C — remove remaining `if: runner.os != 'Windows'` CI
  guards. C-a / C-b / C-c / C-d / C-e / C-f all landed
  post-2026-04-29 (PRs #68, #72, #71, #69, #70). Only **C-g**
  (benchmark Ubuntu-only) remains, and per `CLAUDE.md`'s bench
  policy that one is intentionally Ubuntu-only — Mac M4 Pro
  history.yaml is the authoritative absolute baseline, CI bench is
  the Ubuntu-vs-Ubuntu regression guard. Closing C-g would mean
  either accepting noisy 3-platform comparisons or keeping the
  Ubuntu-only behaviour and just removing the guard; no-op either
  way. Treat W49 as effectively done unless the user wants C-g
  formally closed; detailed status in `@./.dev/resume-guide.md`.

- [ ] W50: Plan B sub-3 — CI Nix-ify. Replace per-tool installs in
  `ci.yml` test matrix with `DeterminateSystems/nix-installer-action`
  + `magic-nix-cache-action` + `nix develop --command bash
  scripts/gate-commit.sh` on Linux/macOS, and
  `pwsh scripts/windows/install-tools.ps1` then `bash scripts/gate-commit.sh`
  on Windows. Then mirror in `nightly.yml`. Plus extend `flake.nix` to
  pin wasm-tools / wasmtime / hyperfine explicitly (URL + sha256)
  rather than via nixpkgs revision. Deferred from overnight 2026-04-29
  because magic-nix-cache had a 2025 outage and macos-latest +
  nix-installer-action has occasional flakes — wants supervised PR.

- [x] W52: realworld coverage on Windows —
  `scripts/windows/install-tools.ps1` extended with rustup-init +
  Go + TinyGo (each pinned via `versions.lock`). Local self-hosted
  Windows reaches 50/50 once the script runs. CI Windows runner
  still 25/25 because it uses per-job `Setup Rust` and does not
  install Go / TinyGo; CI adoption tracked separately under W50.

- [ ] W45: SIMD loop persistence — Skip Q-cache eviction at loop headers.
  Requires back-edge detection in scanBranchTargets.

- [ ] W47: `tgo_strops_cached` post-0.16 regression. Initial framing
  (v1.9.1 64.5ms → v1.10.0 79.9ms cached, +24% on Mac aarch64) was
  based on a 5-run hyperfine sample; 20-run remeasurement on
  2026-04-29 (commit `9a1c76b`) showed both cached and uncached
  variants regressed by ~15.3 % uniformly with σ ≈ 18 % of the
  mean — i.e. the original "cached vs uncached" delta was
  noise-dominated, but a real ~15 % slowdown remains. Variance
  this high makes 5-run bisects unreliable; before code work the
  measurement harness needs stabilising. Full investigation log:
  `@./.dev/w47-investigation.md`. Low priority since 20 other
  benchmarks improved >10% (GC paths 40–76% faster).

- [ ] W48 Phase 2: Linux binary size 1.56 MB → 1.50 MB (~62 KB more).
  W48 Phase 1 shipped (2026-04-25): `pub const panic = std.debug.simple_panic`
  in `src/cli.zig` + `std_options.enable_segfault_handler = false` (zwasm
  installs its own SIGSEGV handler for JIT guard pages anyway) + changed
  `main` from `!void` to `u8` to avoid `dumpErrorReturnTrace` pull-in.
  Net: Linux 1.64 → 1.56 MB (-83 KB, -5%), Mac 1.38 → 1.20 MB (-180 KB).
  CI ceiling tightened from 1.80 MB → 1.60 MB in the same iteration.
  Remaining contributors: `debug.*` still 81 KB (SelfInfo.Elf, Dwarf, writeTrace
  pulled via `std.debug.lockStderr` → `std.Options.debug_io` default),
  `std.Io.Threaded` ~115 KB, `sort.*` ~39 KB. Candidates: override
  `std_options_debug_io` with a minimal direct-stderr Io instance; audit
  whether `init.io` Threaded can be thinned. Acknowledged as a hack against
  stdlib intent — gain vs. risk needs a clean eval before commit.
  Non-blocking; ceiling 1.60 MB still has ~40 KB slack.

## Resolved (summary)

W51: Doc drift — README real-world platform scope clarified
     (Mac+Linux 50/50, Windows 25/25); book/{en,ja}/src/contributing.md
     points at `bash scripts/gate-commit.sh` as the primary entry point
     and lists `scripts/` layout; setup-orbstack.md bumped to current
     pins (Zig 0.16.0, WASI SDK 30, wasm-tools 1.246.1) with a forward
     pointer to the Plan B Nix devshell follow-up; roadmap.md's
     obsolete "Zig version upgrade — High" line replaced with active
     Windows guard removal + CI Nix-ify entries; book/en/src/
     getting-started.md and Japanese mirror dropped the stale
     "Homebrew — coming soon" placeholder. ci.yml benchmark-regression
     comment refreshed (the Zig 0.16.0 migration narrative is no
     longer relevant). Resolved 2026-04-29.

W37: Contiguous v128 storage. W39: Multi-value return JIT (guard removed).
W40: Epoch-based JIT timeout (D131).
W38: SIMD JIT C-compiled perf — Lazy AOT (HOT_THRESHOLD 10→3, back_edge_bailed,
     extract_lane fix, memory_grow64 fix, cross-module instance fix).
W41: JIT real-world correctness — ALL FIXED (Mac 49/50, Ubuntu 50/50).
     void-call reloadVreg, written_vregs pre-scan, void self-call result,
     ARM64 fuel check x0 clobber (tinygo_sort), stale scratch cache in signed
     div (rust_enum_match). Fixed through 2026-03-25.
W42: go_math_big — FIXED (remainder rd==rs1 aliasing in emitRem32/emitRem64).
     emitRem used UDIV+MSUB; UDIV clobbered dividend before MSUB could use
     it. Fix: save rs1 to SCRATCH before division when d aliases rs1.
     Fixed 2026-03-25.
W43: SIMD v128 base addr cache (SIMD_BASE_REG x17). Phase A of D132.
W44: SIMD register class — Q16-Q31 (ARM64) + XMM6-XMM15 (x86) cache.
     Phase B of D132. Merged 2026-03-26. Q-cache with LRU eviction + lazy
     writeback. Benefit limited by loop-header eviction (diagnosed same day).
W46: Un-link libc — Phase 1 complete (delib 1a–1f, merged 2026-04-24/25).
     link_libc=false across lib / cli / tests / examples / e2e / bench / fuzz;
     C API targets (shared-lib, static-lib, c-test) keep link_libc=true because
     `src/c_api.zig` uses `std.heap.c_allocator`. Platform helpers added:
     pfdWrite, pfdRead, pfdClose, pfdDup, pfdDup2, pfdPipe, pfdSleepNs, pfdErrno,
     pfdFsync, pfdReadlinkAt (Linux=direct syscalls, Mac=libSystem auto-link,
     Windows=kernel32/Win32).
     Phase 2 complete (2026-04-25): remaining wasi.zig direct `std.c.*` call
     sites (fdatasync, fcntl, ftruncate, futimens, utimensat, symlinkat,
     linkat, fstatat) routed through new platform helpers (pfdFdatasync,
     pfdFcntlSetfl, pfdFtruncate, pfdFutimens, pfdUtimensat, pfdSymlinkat,
     pfdLinkat, pfdFstatatDarwin). Linux was already libc-free through
     comptime-pruned switches; Phase 2 is a pure refactor with zero
     binary-size delta. Size payoff measured: Mac 1.38 MB, Linux 1.65 MB
     stripped (vs 1.80 MB ceiling). The 1.50 MB target is tracked under W48.

W2-W36: See git history. All resolved through Stages 0-47 and Phases 1-19.
