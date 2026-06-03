# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 = DONE 2026-06-03, `5ab7b981`; Wasm 3.0
  complete on both backends per ADR-0133). §11 task table open (11.0✓ / 11.1 WASI / 11.2 bench / 11.3 SIMD-gap /
  11.4 GC-rooting / 11.P).
- **LAST code HEAD** (`bca625f2`): §11.1 file-I/O bundle **CLOSED** — fd_write/fd_read to file fds
  (std.Io.File.writeStreamingAll / readStreaming; EOF = error.EndOfStream → nread=0). **`zwasm run --dir <tmp>:.
  rust_file_io.wasm` now runs the full create+write+read+unlink flow and exits 0** (was trap). Bundle = cycle 1
  (--dir preopen + path_open O_CREAT, `0b4706b3`) + cycle 2 (file read/write, `bca625f2`); fd-roundtrip regression
  test. rust_file_io is a CAPABILITY pass; gate-visible PASS needs runner --dir wiring (D-243 remainder). Prior:
  fd_filestat_get/path_unlink_file (`b6224bbb`), D-241 verifier-drift fix (`142f0a53`), fd_prestat (`237f0313`).
- **JIT corpus final** (`dbcfff1b`, ubuntu-verified `eba86890`): memory64 336/1(D-234 harness)/0, tail-call
  71/0/0, EH 34/0/0, gc 402/0/5, function-references 36/0/3, multi-memory 0/0/407(→§14). All skips = eligibility-
  gate; all 59 modrej = multi-memory. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`.
- **GATE TRAP** (still live): JIT corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare
  `head -1` = STALE binary → masks the delta.
- **Watch**: `runner_test.zig` ~1490 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 / `validator.zig` 3204 (cap 3300, D-204) — all < hard 2000/3300.

## Active task — §11.1 / §11 continuation  **NEXT**

File-I/O bundle CLOSED (`bca625f2`, rust_file_io exits 0); D-243 reduced to a `note` (capability proven; runner
--dir wiring is cosmetic — rust_file_io is already lenient-PASS/SKIP-EMPTY, not gate-failing). **D-242 RE-DIAGNOSED
this turn** (no code — a throwaway max_frame_stack bump 256→131072 STILL overflowed go_math_big → RUNAWAY frame
growth, NOT a too-shallow stack; tail-call ruled out by code, dispatch.zig pops-then-pushes). D-242 is now a
DEBUG bundle (find the unbounded `call` that never returns via mvp.invoke→dispatch.run re-entry), NOT a
stack-grow. Lesson filed. Next §11 chunks (pick by value):
- **D-242 debug bundle**: instrument frame_len growth on go_math_big, capture the repeating call site, fix the
  interp semantics (interp miscompile / Go re-entry model). The real go_* lever.
- **11.2 bench infra** (already substantially built: run_bench.sh --quick, history.yaml, record scripts — assess
  what's left) / **11.4 GC-on-JIT rooting** (D-211).
- More preview1 syscalls (fd_readdir, path_create_directory, path_rename, fd_seek-for-files) — completeness; no
  fixture currently needs them (all realworld imports resolve, 0 SKIP-WASI).

§10 close-hygiene RESOLVED (SHA traceability via `5ab7b981` + phase_log; windowsmini DEFERRED per policy).

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

THIS turn = D-242 RE-DIAGNOSIS (DOCS-ONLY, no code): the go_* CallStackExhausted is RUNAWAY frame growth, not a
too-shallow stack — proven by a throwaway max_frame_stack 256→131072 bump that STILL overflowed go_math_big
(reverted). Re-scoped D-242 to a debug bundle + filed the runaway-vs-deep lesson; reduced D-243 to note. NO code
change → NO ubuntu kick (prior `bca625f2` already ubuntu-OK at `95b8efe6`; Step 0.7 next cycle = nothing to
verify). Next → the D-242 debug bundle (instrument the runaway call site) or 11.2 bench.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); pick the exe by mtime (bare `head -1` = STALE). `ZWASM_SPEC_ENGINE=jit <exe>
test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Phase 11 adds WASI + bench gates.

## Key refs

- ROADMAP §11 (WASI 0.1 + bench + SIMD gap + GC-rooting). ADR-0128 (Phase 10); ADR-0133 (§10 re-scoped exit);
  ADR-0067 (3-host bench: Mac native + ubuntunote + windowsmini). `debug_jit_auto` skill for JIT dispatch fails.
- Lessons (this session): `2026-06-03-reprobe-blocked-by-barriers-before-scoping` (D-240 + D-210),
  `2026-06-03-jitinstance-test-compiles-for-host-arch`, `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`.
