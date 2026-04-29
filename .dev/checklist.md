# Deferred Work Checklist

Open items only. Resolved items in git history.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open Items

- [ ] W49 / Plan C-g: 3-platform bench baseline reset. The other
  Plan C items (C-a..C-f) landed in PRs #68..#74. C-g schema
  foundation shipped via PR #86 (2026-04-29 evening): every
  `bench/history.yaml` entry now carries an `arch:` field;
  `bench/record.sh` auto-detects the target triple and scopes
  duplicate-id checks by `(id, arch)`; `record-merge-bench.sh`
  dropped the Darwin-only guard. `e5766ee` (the C-g merge itself)
  is the first SHA with multiple platform rows — `aarch64-darwin`
  native and `x86_64-linux` via OrbStack Rosetta. Remaining work:
  (a) pin hyperfine in versions.lock + `install-tools.ps1`,
  (b) collect a native x86_64-linux baseline (the OrbStack row is
  Rosetta-translated, schema-shakedown only), (c) collect a
  Windows baseline once hyperfine is on PATH, (d) drop
  `runs-on: ubuntu-latest` on the `benchmark` CI job and switch
  to a 3-OS matrix.

- [x] W50: Plan B sub-3 — CI Nix-ify. Shipped in 4 PRs over the
  2026-04-29 PM autonomous session:
  - **PR-A (#80)** — `flake.nix` gained explicit URL+sha256 pins for
    wasm-tools 1.246.1 + wasmtime 42.0.1; hyperfine kept on nixpkgs
    because upstream has no aarch64-darwin prebuilt. `sync-versions.sh`
    extended to verify the two new pins.
  - **PR-B (#81)** — new `test-nix` job for Linux,
    `DeterminateSystems/nix-installer-action` + `magic-nix-cache-action`
    + `nix develop --command bash scripts/gate-commit.sh`.
  - **PR-C (#82)** — `test-nix` matrix extended to macOS.
  - **PR-D (#83)** — Windows test job switched to
    `pwsh scripts/windows/install-tools.ps1 -SkipRust` +
    `bash scripts/gate-commit.sh`. Added binaryen 125 to
    install-tools.ps1 (TinyGo wasm-opt requirement, found by CI).
    Restored c-test / static-lib / static-link / Rust example /
    memory-check extras across all 3 OSes; reordered cargo run
    before static-lib build because Windows has filename collision
    on `zwasm.lib`. `nightly.yml` mirror left as a future follow-up
    — its sanitizer + fuzz jobs are Linux-only and don't surface on
    PR CI.

- [x] W53: `install-tools.ps1` rust install path bug. Root cause:
  PowerShell folds every native command's stdout into the enclosing
  function's pipeline output. Inside `Install-Rustup`, rustup-init's
  `info: downloading component rust-std` (and the same lines from
  `& rustup target add wasm32-wasip1`) were piling up alongside the
  trailing `return $stampedDir`, so the caller's `$rustRoot` was a
  string array rather than a single path; downstream
  `Join-Path $paths['rust'] 'cargo'` then failed parameter binding
  on the empty leading element. Local Windows was unaffected
  because rustup's "already installed" path is silent on stdout, so
  nothing leaked into the function's return value there. Fix routes
  both native command invocations through `2>&1 | Out-Host`, keeping
  the lines visible in the CI log while pulling them out of the
  pipeline; added a defensive `[array]` / IsNullOrWhiteSpace check
  in the caller. CI's `test (windows-latest)` job dropped both
  `-SkipRust` and the separate `Setup Rust` step — the runner now
  goes through a single `install-tools.ps1` path with a
  self-contained `%LOCALAPPDATA%\zwasm-tools\rust-stable\`
  toolchain, mirroring the local Windows experience.

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

- [ ] W54: `tgo_strops` (and other div-heavy TinyGo workloads) is
  ~2.1× slower than wasmtime/cranelift on M4 Pro per
  `bench/runtime_comparison.yaml` (2026-03-25, runs=1/warmup=0):
  zwasm cached 63.2 ms vs wasmtime cached 30.0 ms. Current main
  (`448f4c8`) is ~67 ms cached, so the gap is recurring, not a
  measurement artefact, and it dwarfs the W47 +15 % post-0.16
  regression. The hot loop is TinyGo's `digitCount` —
  `i32.div_u 10 + br_if` in a `for v > 0` loop — and the lever is
  the constant-divisor optimisation. Strategy stack, ordered by
  leverage and single-pass compatibility:

  1. **Constant-divisor → multiply-high (Hacker's Delight 10-9)**
     in predecode. Detect `i32.const K; i32.div_u` (and `rem_u`,
     plus `mul K` for power-of-two / shift-add) in a 2-instruction
     window, rewrite to a synthetic `udiv_const K` RegIR op. JIT
     emits `MOVZ m; UMULH tmp, n, m; LSR result, tmp, s` on
     ARM64; `MOV m; MUL r/m32; SHR edx, s` on x86_64. Magic
     numbers are pure constants of K, computed once. UDIV is
     8–10 cycles vs UMULH+LSR ~3–4 cycles, so realistic gain on
     `digitCount` is ~30–40 ms cached → close to wasmtime parity.
     Pure peephole; preserves single-pass.
  2. **Loop-header Q-cache persistence** (existing W45). Detect
     back-edges in `scanBranchTargets` and skip the Q-cache
     evict at the loop header so the induction var stays in a
     register. Helps `tgo_strops`, `tgo_arith`, `tgo_fib_loop`,
     `st_nestedloop`. Already designed; cheap to land.
  3. **`br_if` fall-through ordering audit**. cranelift always
     places the fall-through arm as the loop continuation so the
     branch predictor wins. Confirm `regalloc.zig`'s terminator
     emit does the same and mirror it if not. Cheap audit.
  4. **Interpreter dispatch codegen diff** (also closes W47). asm
     diff `vm.zig`'s hot dispatch loop between v1.9.1 and main
     under Zig 0.16 / LLVM 19. The post-0.16 +15 % most likely
     lives here, and a fix would lift every interpreter path,
     not just `tgo_strops`.

  Out of scope (would break single-pass): SSA + dataflow,
  global register allocation beyond linear scan, automatic loop
  unroll / vectorise.

  Measurement note: `runtime_comparison.yaml` is currently runs=1
  / warmup=0 — useful for ordering, not for absolute targets.
  Re-record at 5 runs / 3 warmup before claiming a win.

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
