# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 = DONE 2026-06-03, `5ab7b981`; Wasm 3.0
  complete on both backends per ADR-0133). §11 task table open (11.0✓ / 11.1 WASI / 11.2 bench / 11.3 SIMD-gap /
  11.4 GC-rooting / 11.P).
- **LAST code HEAD** (`7806936f`): **D-242 RESOLVED** — per-frame LABEL stack now spills to a lazy heap overflow.
  Root cause was `max_label_stack = 128 < validator max_control_stack = 1024` (D-241 drift family): standard-Go's
  wasip1 output nests control >128, validated but trapped StackOverflow at `frame.pushLabel`. Fix: `label_buf [128]`
  inline + lazy `label_overflow []Label` (cap = `zir.max_control_stack`, freed once at popFrame); `pushLabel` takes
  an allocator (threaded through 3 interp handler sites + 4 test sites). **All 9 `go_*` realworld fixtures now exit
  0; `zig build test-realworld-run` = 55/55 passed, 0 SKIP-WASI, 0 failed.** Regression test in runtime.zig.
- **§11.1 file-I/O** (prior `bca625f2`): `zwasm run --dir <tmp>:. rust_file_io.wasm` runs create+write+read+unlink,
  exits 0 (fd_write/fd_read to file fds, path_open O_CREAT, --dir CLI flag). CAPABILITY complete; D-243 remainder =
  wire the realworld DIFF runner to pass a temp `--dir` (gate-visibility only; behaviour proven).
- **JIT corpus final** (`dbcfff1b`, ubuntu-verified `eba86890`): memory64 336/1(D-234)/0, tail-call 71/0/0, EH
  34/0/0, gc 402/0/5, function-references 36/0/3, multi-memory 0/0/407(→§14). Spec corpus = interp default; JIT
  opt-in `ZWASM_SPEC_ENGINE=jit`.
- **GATE TRAP** (still live): JIT corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare
  `head -1` = STALE binary → masks the delta.
- **Watch**: `runner_test.zig` ~1490 / `runner_gc_test.zig` 1499 / `jit_abi.zig` 1364 / `validator.zig` 3267 (cap
  3300, D-204) — all < hard.

## Next task (autonomous)

§11.1 remaining is gate-visibility + Windows subset; §11.2 bench infra is the next sequential row. Pick whichever:

- **§11.1 finish**: (a) D-243 remainder — realworld DIFF runner `--dir` wiring so rust_file_io flips SKIP-V2-TRAP →
  gate PASS (diff_runner must give wasmtime the same `--dir` + matching guest path); (b) Windows realworld subset
  (25 samples) reconciliation. More preview1 syscalls = completeness only (0 SKIP-WASI remain).
- **§11.2 bench**: substantially built (run_bench.sh --quick / history.yaml / record scripts); assess what's left
  for per-merge auto-recording (Mac + ubuntunote + windowsmini per ADR-0067).

## Deferred / open debt (all blocked-by/note; none a Phase-11 blocker)

- **D-243** realworld DIFF-runner preopen-sandbox wiring (file-I/O CAPABILITY done; gate-visibility remainder; §11.1).
- **D-211** GC-on-JIT precise rooting → §11.4 (emit DONE; only rooting deferred, safe per non-moving+no-reclaim).
- **D-210** cross-module frame-consuming TC cohort stack-save (terminating programs correct; not a corpus gap).
- **D-238** x86_64 cross-instance EH thunk parity (arm64 done; FP-walk MOV + RBP variant).
- **D-234** memory64 OOB harness false-report (codegen proven correct 6 paths; runner-side fix).
- D-237 spec-runner double-free (harness); D-229/D-231 x86_64 follow-ons (note); D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21, toolchain provisioned).

## Step 0.7 (next resume)

THIS turn LANDED CODE (`7806936f`, D-242 label-overflow fix) → ubuntu kick fired against it. Step 0.7 next cycle =
`tail -3 /tmp/ubuntu.log` mechanically; on FAIL revert the commit pair to the last ubuntu-verified HEAD. Mac gate
(`scripts/mac_gate.sh`) + all 3 cross-targets (x86_64-linux/aarch64-macos/x86_64-windows) were green pre-push.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); pick the exe by mtime (bare `head -1` = STALE). `ZWASM_SPEC_ENGINE=jit <exe>
test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr).

## Key refs

- ROADMAP §11 (WASI 0.1 + bench + SIMD gap + GC-rooting). ADR-0128 (Phase 10); ADR-0133 (§10 re-scoped exit);
  ADR-0067 (3-host bench). `debug_jit_auto` skill for JIT dispatch fails.
- Lessons (this session): `2026-06-03-callstackexhausted-diagnose-runaway-vs-deep` (D-242, now RESOLVED),
  `2026-06-03-sanity-check-must-share-the-real-gates-constant` (D-241),
  `2026-06-03-reprobe-blocked-by-barriers-before-scoping` (D-240 + D-210).
