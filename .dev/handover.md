# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 = DONE 2026-06-03, `5ab7b981`; Wasm 3.0
  complete on both backends per ADR-0133). §11 task table open (11.0✓ / 11.1 WASI / 11.2 bench / 11.3 SIMD-gap /
  11.4 GC-rooting / 11.P).
- **§11.2 bench (paths verified, `1c13e9f3`+`d303f427`)**: `record_merge_bench.sh` un-stubbed → thin wrapper over
  the real `run_bench.sh` hyperfine engine (Mac: `--quick --bench=tinygo/arith` → mean_ms=2.39). `run_remote_ubuntu.sh`
  gained a `bench` step (runs the recorder under the remote nix shell; hyperfine 1.20.0 confirmed on ubuntunote) →
  Linux row path verified (`bench --quick --bench=tinygo/arith` wrote a real x86_64-linux recent.yaml row).
  §12.4 cadence: Phase 0-13 = MANUAL recording; auto-CI `bench.yml` push-trigger DISABLED 2026-05-25 per user —
  do NOT re-enable, do NOT wire `gate_merge.sh`. REMAINING (phase-close batch): committed 3-host `--phase-record`
  baseline rows into `history.yaml` (Mac local + Linux via `append_bench_to_history.sh` fragment extract/append +
  windowsmini) — §11.P exit "bench auto-record 3-host". Use `--windows-subset` (5 light benches) for fast runs;
  heavy benches (fib2) take minutes each.
- **LAST code HEAD** (`89aaebcf`): **D-243 RESOLVED** — the realworld DIFF runner now preopens a fresh scratch
  `--dir` (guest ".") for needs-preopen fixtures on BOTH sides (wasmtime `--dir <scratch>::.` + v2
  `runWasmCapturedOpts`). `rust_file_io.wasm` flips SKIP-V2-TRAP → **MATCH** (`zig build test-realworld-diff` =
  50/55 matched, 0 mismatched, 0 skipped-v2). Prior `7806936f`: **D-242 RESOLVED** — per-frame label stack spills
  to a lazy heap overflow (`max_label_stack` = `zir.max_control_stack`, was a stale 128 < validator 1024); all 9
  `go_*` exit 0, `test-realworld-run` 55/55, 0 SKIP-WASI. **§11.1 WASI capability + gate-visibility = DONE on Mac;
  only the Windows realworld subset (25 samples, windowsmini) remains, deferred to the phase-boundary batch.**
- **JIT corpus final** (`dbcfff1b`, ubuntu-verified `eba86890`): memory64 336/1(D-234)/0, tail-call 71/0/0, EH
  34/0/0, gc 402/0/5, function-references 36/0/3, multi-memory 0/0/407(→§14). Spec corpus = interp default; JIT
  opt-in `ZWASM_SPEC_ENGINE=jit`.
- **GATE TRAP** (still live): JIT corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare
  `head -1` = STALE binary → masks the delta.
- **Watch**: `runner_test.zig` ~1490 / `runner_gc_test.zig` 1499 / `jit_abi.zig` 1364 / `validator.zig` 3267 (cap
  3300, D-204) — all < hard.

## Active bundle

- **Bundle-ID**: 11.3-simd-gap (D-074 cohort)
- **Cycles-remaining**: ~2 (corpus+run_bench+gap-script landed; D-245 ReleaseSafe fix, then the gap run/close)
- **Continuity-memo**: §11.3 SIMD per-op gap analysis = v2 vs **median of (wasmtime, wazero, wasmer)**, flag ops
  lagging >3×, file Phase-15 debt. DONE: ch1 (`e6dd3f94`) wazero+wasmer in flake; ch2 (`843cc7de`)
  `run_bench.sh --compare={wazero,wasmer,all}` (all 4 switch-sites) + `pkgs.git` in flake (macOS /usr/bin/git is
  an xcrun shim that dies under `nix develop`, where the gap run must execute). Verified: `nix develop --command
  bash -c 'run_bench.sh --quick --bench=tinygo/arith --compare=all'` records 4 runtime rows, exit 0.
  **DONE**: --engine=jit path (`8011293a`, ADR-0136); SIMD corpus ch3 (`728a43cb`, 12 fixtures + gen script);
  run_bench `--simd` ch4a (`82f20fe4`); wasmer Mac-only gate fix (`26d29e33`); gap-analysis SCRIPT ch4b
  (`bb01be43`, `scripts/simd_gap_analysis.sh` — correct, comparator columns verified). **BLOCKED — D-245
  (ROOT-CAUSED `2fc12ba8`)**: `--engine=jit` SEGVs in ReleaseSafe (works Debug) on ANY module incl. empty
  `_start` → `run_bench.sh` (ReleaseSafe) records `null` for zwasm. Cause: host→JIT call doesn't preserve
  callee-saved regs — the arm64 prologue MOV-installs the cohort (X19/X24/X28) from rt w/o saving the caller's
  (ADR-0017/D-210), but `entry.invokeAndCheckVoid` calls via plain `@call` (callconv c); ReleaseSafe keeps host
  values live in X19-X28 → clobbered → host frees garbage. LATENT PROJECT-WIDE (all host→JIT ReleaseSafe-unsafe;
  masked by Debug-only runs). **NEXT chunk = FIX D-245**: a callee-saved-preserving asm trampoline at the
  `invokeAndCheck*` seam (save/restore arm64 X19-X28+FP/LR, x86_64 RBX/RBP/R12-R15 around the `blr`/`call`);
  survey if a register-preserving entry already exists to route through; ADD a **ReleaseSafe** runWasmJit test.
  THEN re-run `run_bench.sh --simd --compare=all` + `simd_gap_analysis.sh` → file Phase-15 debt (incl.
  dot/extmul arm64-NotImplemented) → close bundle + flip §11.3.
- **Exit-condition**: (after D-245) a `--simd --compare=all` run emits a per-op zwasm/median ratio table +
  Phase-15 debt for every op > 3× (and the dot/extmul gap).

§11.1/§11.2 phase-close-batch items (Windows realworld subset + windowsmini bench row + committed 3-host bench
rows) remain for §11.P. §11.4 moved to Phase 15 (ADR-0135).

## Deferred / open debt (all blocked-by/note; none a Phase-11 blocker)

- **D-211** GC-on-JIT precise rooting → **Phase 15** (ADR-0135; paired with reclamation; emit DONE, rooting safe
  to defer per non-moving+no-reclaim). Residual: no struct/array/ref_cast JIT op-emit file (interp-only) — noted.
- **D-210** cross-module frame-consuming TC cohort stack-save (terminating programs correct; not a corpus gap).
- **D-238** x86_64 cross-instance EH thunk parity (arm64 done; FP-walk MOV + RBP variant).
- **D-234** memory64 OOB harness false-report (codegen proven correct 6 paths; runner-side fix).
- D-237 spec-runner double-free (harness); D-229/D-231 x86_64 follow-ons (note); D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21, toolchain provisioned).

## Step 0.7 (next resume)

`b60b2f87` ubuntu test-all = GREEN this cycle (`OK (HEAD=b60b2f87)`, all `fail=0`) — the wasmer Mac-only fix
unbroke the dev shell AND `runWasmJit` passes on x86_64 (Debug). THIS turn = scripts (gap-analysis) + debt/docs
only, no src committed → NO ubuntu kick (non-code gap). Last ubuntu-verified code HEAD = `b60b2f87`. Next cycle
Step 0.7 = nothing to verify; the D-245 fix WILL be a src change → kick then.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); pick the exe by mtime (bare `head -1` = STALE). `ZWASM_SPEC_ENGINE=jit <exe>
test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr).

## Key refs

- ROADMAP §11 (WASI 0.1 + bench + SIMD gap + GC-rooting). ADR-0128 (Phase 10); ADR-0133 (§10 re-scoped exit);
  ADR-0067 (3-host bench). `debug_jit_auto` skill for JIT dispatch fails.
- Lessons (this session): `2026-06-03-callstackexhausted-diagnose-runaway-vs-deep` (D-242, now RESOLVED),
  `2026-06-03-sanity-check-must-share-the-real-gates-constant` (D-241),
  `2026-06-03-reprobe-blocked-by-barriers-before-scoping` (D-240 + D-210).
