# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 = DONE 2026-06-03, `5ab7b981`; Wasm 3.0
  complete on both backends per ADR-0133). §11 task table open (11.0✓ / 11.1 WASI / 11.2 bench / 11.3 SIMD-gap /
  11.4 GC-rooting / 11.P).
- **LAST code HEAD** (`b6224bbb`): §11.1 — WASI `fd_filestat_get` + `path_unlink_file` (preview1 16→18), closing
  rust_file_io's import gap → **facade-runner 55 PASS / 0 SKIP-WASI / 0 FAIL**. Full rust_file_io execution still
  needs a preopen sandbox (runners configure none; wasmtime panics NotFound without --dir) → **D-243**. Unit-tested
  (stdio/badf/notdir/notcapable), mac_gate + 2-arch xc green. Prior code: **D-241 RESOLVED** (`142f0a53`): the IR
  verifier's branch-depth ceiling was a stale literal 256 drifted from the validator's `max_control_stack` (1024)
  → standard-Go funcs wrongly rejected → fixed via shared `zir.max_control_stack` + drift-guard test; go_* now
  instantiate but trap (CallStackExhausted, 256-frame interp stack too shallow → **D-242**); diff_runner gained
  precise v2-trap→SKIP-V2-TRAP categorisation (both-exit-0-
  different still MISMATCH, no masking). Prior: WASI fd_prestat/sched_yield (`237f0313`). mac_gate + 2-arch xc green.
- **JIT corpus final** (`dbcfff1b`, ubuntu-verified `eba86890`): memory64 336/1(D-234 harness)/0, tail-call
  71/0/0, EH 34/0/0, gc 402/0/5, function-references 36/0/3, multi-memory 0/0/407(→§14). All skips = eligibility-
  gate; all 59 modrej = multi-memory. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`.
- **GATE TRAP** (still live): JIT corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare
  `head -1` = STALE binary → masks the delta.
- **Watch**: `runner_test.zig` ~1490 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 / `validator.zig` 3204 (cap 3300, D-204) — all < hard 2000/3300.

## Active task — §11.1 WASI continuation  **NEXT**

§10 close-hygiene RESOLVED: (1) §10 SHA backfill = NOT fabricated — Phase 10 commits aren't row-tagged, so per-row
SHAs would be guesses; traceability = the close commit `5ab7b981` (body lists per-feature SHAs) + `phase_log/phase10.md`.
(2) windowsmini reconciliation = DEFERRED per user policy (batch-resolve later).

The realworld WASI fixtures' remaining gaps are now all DEEP (not single chunks): D-242 (frame stack, go_*),
D-243 (preopen sandbox, rust_file_io). Next §11.1 chunks (pick by value):
- **D-243 preopen sandbox**: CLI `--dir` flag + host `addPreopen` + runners pass a temp dir → file-I/O fixtures
  (rust_file_io) run to completion. Medium (CLI flag + wiring); also probe the facade↔CLI instantiate divergence.
- **D-242 growable interp frame stack** (go_* full PASS): replace fixed `[256]Frame frame_buf` with a heap-backed
  growable stack. Multi-cycle bundle (Runtime struct + every frame push/pop + stack-probe).
- Or 11.2 bench auto-record, 11.4 GC-on-JIT rooting (D-211). All preview1 syscalls go_*/rust need are now wired;
  remaining preview1 surface (fd_readdir, path_create_directory, path_rename, …) lands as fixtures demand.

## Deferred / open debt (all blocked-by/note; none a Phase-11 blocker yet)

- **D-211** GC-on-JIT precise rooting → §11.4 (emit DONE; only rooting deferred, safe per non-moving+no-reclaim).
- **D-210** cross-module frame-consuming TC cohort stack-save (terminating programs correct; not a corpus gap).
- **D-238** x86_64 cross-instance EH thunk parity (arm64 done; FP-walk MOV + RBP variant).
- **D-234** memory64 OOB harness false-report (codegen proven correct 6 paths; runner-side fix).
- **D-242** interp 256-frame call stack too shallow for standard-Go runtime (go_* CallStackExhausted; §11.1 above).
- **D-243** no preopen-sandbox wiring for file-I/O fixtures (rust_file_io instantiates but can't open files; §11.1).
- D-237 spec-runner double-free (harness); D-229/D-231 x86_64 follow-ons (note); D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21, toolchain provisioned).

## Step 0.7 (next resume)

THIS turn = §11.1 WASI fd_filestat_get + path_unlink_file (`b6224bbb`, CODE): preview1 16→18, rust_file_io
imports closed (facade 55 PASS); D-243 filed (preopen sandbox needed for full file-I/O). mac_gate (test-all+lint)
green, 2-arch xc clean. **ubuntu kick SENT** against `b6224bbb` — Step 0.7 next cycle MUST `tail -3 /tmp/ubuntu.log`;
RED → revert to `4b78ba41` (last ubuntu-verified). Next → D-243 preopen wiring or D-242 frame-stack bundle.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); pick the exe by mtime (bare `head -1` = STALE). `ZWASM_SPEC_ENGINE=jit <exe>
test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Phase 11 adds WASI + bench gates.

## Key refs

- ROADMAP §11 (WASI 0.1 + bench + SIMD gap + GC-rooting). ADR-0128 (Phase 10); ADR-0133 (§10 re-scoped exit);
  ADR-0067 (3-host bench: Mac native + ubuntunote + windowsmini). `debug_jit_auto` skill for JIT dispatch fails.
- Lessons (this session): `2026-06-03-reprobe-blocked-by-barriers-before-scoping` (D-240 + D-210),
  `2026-06-03-jitinstance-test-compiles-for-host-arch`, `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`.
