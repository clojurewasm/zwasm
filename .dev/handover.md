# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 DONE 2026-06-03 `5ab7b981`; Wasm 3.0 both
  backends per ADR-0133). §11 table: 11.0✓ / 11.1 WASI / 11.2 bench / **11.3 SIMD-gap ✓** / 11.4→Phase 15 / 11.P.
- **LAST code HEAD** (`0c42e913`): **D-245 FIXED both gate arches + regression-gated** — `zwasm run --engine=jit`
  SEGV'd in ReleaseSafe (host→JIT call didn't preserve the callee-saved regs the JIT clobbers per ADR-0017/D-210).
  `invokeAndCheckVoid`'s no-arg path now calls via asm save/restoring the host callee-saved: arm64 stp/ldp
  X19-X28 (`8eca59e3`); x86_64 push/pop RBX/R12-R15+align (`de576a76`, ubuntu-ReleaseSafe-verified). Locked by
  `scripts/check_jit_releasesafe.sh` (build ReleaseSafe + run SIMD `_start` via `--engine=jit`) wired into
  gate_merge (`0c42e913`); also silenced the leftover `[stack_probe]` stderr in release builds. REMAINDER (D-245
  partial, minor): win64 + arg'd `invokeAndCheck*` variants still `@call` (Debug-only-used / windowsmini).
- **§11.3 SIMD gap = DONE** (`dbaa1a03`): profile `bench/results/simd_gap_profile_p11_3.md` — zwasm JIT competitive,
  **0/12 ops > 3× the median** of (wasmtime,wazero,wasmer). §9.10 Track A opts NOT gap-justified (stay
  opportunistic). Categorical gap = arm64 JIT lacks dot/extmul emit (x86_64 has it) → **D-246** (Phase 15).
  Infra: `--engine=jit` (ADR-0136, `8011293a`); SIMD corpus + `gen_simd_corpus.sh` (`728a43cb`); `run_bench.sh
  --simd`/`--compare={wazero,wasmer,all}` (`82f20fe4`,`843cc7de`); `simd_gap_analysis.sh` (`bb01be43`); wazero/wasmer
  Mac-only in flake (`26d29e33` — wasmer won't build on x86_64-linux).
- **§11.1 WASI** = Mac-side DONE (0 SKIP-WASI; go_* exit 0 via D-242 fix; rust_file_io MATCH via D-243); Windows
  realworld subset (25 samples, windowsmini) = phase-close batch.
- **§11.2 bench** = recording paths verified Mac + Linux (`record_merge_bench.sh`→`run_bench.sh`;
  `run_remote_ubuntu.sh bench`); committed 3-host `--phase-record` history.yaml rows = phase-close batch
  (auto-CI `bench.yml` push-trigger stays DISABLED per user 2026-05-25 — do NOT re-enable / wire gate_merge).
- **GATE TRAP**: JIT corpus exe MUST be mtime-picked (`find … -exec ls -t {} + | head -1`); bare `head -1` = STALE.
- **Watch**: `entry.zig` 2864 (cap 3000) / `validator.zig` 3267 (cap 3300) / runner_test ~1490 — all < hard.

## Next task (autonomous)

Phase-11 substantive code work is essentially complete (§11.1 Mac WASI, §11.2 bench paths, §11.3 SIMD gap,
D-245 both-arch + regression-gated). Remaining is mostly windowsmini phase-close batch + minor polish. Next
autonomous (Mac-doable), in priority order: (1) **§11.2 Mac bench baseline** — `record_merge_bench.sh
--windows-subset --phase-record` → a real committed aarch64-darwin `history.yaml` row (toward §11.P "bench
3-host"); (2) D-245 remainder (win64 + arg'd `invokeAndCheck*` variants, same asm-save — Debug-only-used).
Then the §11.P windowsmini batch (11.1 Windows realworld subset + Linux/Windows committed bench rows) → §11.P
close + audit_scaffolding. (NOTE: §11.P close needs windowsmini — likely a user-touchpoint/bucket-3 eventually.)

## Deferred / open debt (none a Phase-11 blocker)

- **D-245** host→JIT callee-saved: arm64 + x86_64 no-arg-void FIXED (`8eca59e3`,`de576a76`); win64 + arg'd
  variants + ReleaseSafe regression test = remainder (partial).
- **D-246** §11.3 → Phase 15: arm64 dot/extmul JIT-emit hole + SIMD-emit coverage sweep; steady-state re-profile.
- **D-211** GC-on-JIT precise rooting → Phase 15 (ADR-0135; paired with reclamation).
- **D-244** SIMD interp-free by design (partial; `--engine=jit` now runs compute SIMD via JIT; WASI-under-JIT = d-3).
- **D-210** cross-module frame-consuming TC; **D-238** x86_64 cross-instance EH thunk; **D-234** memory64 OOB harness.
- D-237 spec double-free; D-229/D-231 x86_64 follow-ons; D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21).

## Step 0.7 (next resume)

Prior `7284ddca` (D-245 x86_64) = ubuntu test-all GREEN. THIS turn landed `0c42e913` (stack_limit.zig Debug-gate +
the regression gate scripts) → a Debug ubuntu test-all kick fires for the turn HEAD (confirms no Debug regression;
the stack_limit gate only changes release output). The ReleaseSafe regression itself was verified locally
(`check_jit_releasesafe.sh` exit 0). Step 0.7 next cycle = `tail -3 /tmp/ubuntu.log`; on FAIL revert to `7284ddca`.

**Gate hygiene**: Step-5 = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert` (mtime exe).
ReleaseSafe `--engine=jit` repro: `zig build -Doptimize=ReleaseSafe && zig-out/bin/zwasm run --engine=jit <fixture>`.

## Key refs

- ROADMAP §11 (WASI + bench + SIMD gap). ADR-0136 (`--engine=jit`); ADR-0135 (§11.4→P15); ADR-0017/D-210 (cohort).
- Lessons (this session): `2026-06-03-host-to-jit-must-preserve-callee-saved` (D-245),
  `2026-06-03-callstackexhausted-diagnose-runaway-vs-deep` (D-242).
- `bench/results/simd_gap_profile_p11_3.md` (§11.3 profile). `debug_jit_auto` skill for JIT crashes.
