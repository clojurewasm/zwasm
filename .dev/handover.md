# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 DONE 2026-06-03 `5ab7b981`; Wasm 3.0 both
  backends per ADR-0133). §11 table: 11.0✓ / 11.1 WASI / 11.2 bench / **11.3 SIMD-gap ✓** / 11.4→Phase 15 / 11.P.
- **LAST code HEAD** (`8eca59e3`): **D-245 arm64 FIXED** — `zwasm run --engine=jit` SEGV'd in ReleaseSafe (host→JIT
  call didn't preserve callee-saved X19-X28 the arm64 JIT clobbers per ADR-0017/D-210). `invokeAndCheckVoid`'s
  no-arg arm64 path now calls via an asm BLR that manually `stp`/`ldp` X19-X28 (clobber-listing all 10
  over-constrains the allocator). ReleaseSafe SIMD corpus → exit 0; test+lint+3-arch xcompile+mac_gate green.
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

**D-245 x86_64 remainder** — the host→JIT callee-saved fix is arm64-only so far; x86_64-SysV/win64 entries + the
arg'd / i32 / v128 `invokeAndCheck*` variants still use plain `@call` → `--engine=jit` is ReleaseSafe-unsafe on
Linux (Debug fine; not §11.3-blocking since the gap bench is Mac-only, but the feature should work in release on
all arches). Same fix: asm `call` saving/restoring x86_64 callee-saved (RBX/RBP/R12-R15) around the JIT call;
add a **ReleaseSafe** runWasmJit test (the Debug-only test let D-245 ship). Then the §11.P phase-close batch:
11.1 Windows realworld subset + 11.2 committed 3-host bench rows (both windowsmini) → §11.P close + audit.

## Deferred / open debt (none a Phase-11 blocker)

- **D-245** host→JIT callee-saved: arm64 fixed (`8eca59e3`); x86_64/win64 + arg'd-variant remainder (above).
- **D-246** §11.3 → Phase 15: arm64 dot/extmul JIT-emit hole + SIMD-emit coverage sweep; steady-state re-profile.
- **D-211** GC-on-JIT precise rooting → Phase 15 (ADR-0135; paired with reclamation).
- **D-244** SIMD interp-free by design (partial; `--engine=jit` now runs compute SIMD via JIT; WASI-under-JIT = d-3).
- **D-210** cross-module frame-consuming TC; **D-238** x86_64 cross-instance EH thunk; **D-234** memory64 OOB harness.
- D-237 spec double-free; D-229/D-231 x86_64 follow-ons; D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21).

## Step 0.7 (next resume)

THIS turn landed `8eca59e3` (D-245 arm64 fix — entry.zig asm) → ubuntu test-all kick fires against the turn's HEAD.
Step 0.7 next cycle = `tail -3 /tmp/ubuntu.log`; on FAIL revert the turn's commits to `b60b2f87` (last ubuntu-green).
Note: ubuntu test-all is DEBUG → it won't exercise the ReleaseSafe path; it verifies no Debug regression from the
asm change. The arm64 asm is comptime-gated (`arch == .aarch64`) so x86_64 takes the unchanged `@call`.

**Gate hygiene**: Step-5 = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert` (mtime exe).
ReleaseSafe `--engine=jit` repro: `zig build -Doptimize=ReleaseSafe && zig-out/bin/zwasm run --engine=jit <fixture>`.

## Key refs

- ROADMAP §11 (WASI + bench + SIMD gap). ADR-0136 (`--engine=jit`); ADR-0135 (§11.4→P15); ADR-0017/D-210 (cohort).
- Lessons (this session): `2026-06-03-host-to-jit-must-preserve-callee-saved` (D-245),
  `2026-06-03-callstackexhausted-diagnose-runaway-vs-deep` (D-242).
- `bench/results/simd_gap_profile_p11_3.md` (§11.3 profile). `debug_jit_auto` skill for JIT crashes.
