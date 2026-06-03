# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 = DONE 2026-06-03, `5ab7b981`; Wasm 3.0
  complete on both backends per ADR-0133). §11 task table open (11.0✓ / 11.1 WASI / 11.2 bench / 11.3 SIMD-gap /
  11.4 GC-rooting / 11.P).
- **LAST code HEAD** (`142f0a53`): §11.1 — **D-241 RESOLVED**: the IR verifier's branch-depth ceiling was a stale
  literal 256 that drifted from the validator's `max_control_stack` (now 1024) → validator-accepted standard-Go
  funcs (depth 256-1023) wrongly rejected → all 9 `go_*` failed to instantiate. Fix = shared `zir.max_control_stack`
  (both validator + verifier source it; drift-guard test). go_* now instantiate (facade 54 PASS, strict — reverted
  the SKIP-INST tolerance). Cascade: go_* now RUN but trap (CallStackExhausted — 256-frame interp stack too shallow
  for Go's runtime → **D-242**, deeper); diff_runner gained precise v2-trap→SKIP-V2-TRAP categorisation (both-exit-0-
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

Next §11.1 chunks (pick by value):
- **rust_file_io** still SKIP-WASI (one more missing preview1 import — likely a path_* / fd_filestat call; grep
  its imports vs lookupWasiThunk). Small, self-contained — good next chunk.
- **D-242 growable interp frame stack** (full go_* support): replace the fixed `[256]Frame frame_buf` with a
  heap-backed/growable stack so Go's runtime init doesn't CallStackExhaust; then go_* run to completion +
  diff_runner SKIP-V2-TRAP → MATCH. Multi-cycle bundle (Runtime struct + every frame push/pop + stack-probe).
- Or 11.2 bench auto-record, 11.4 GC-on-JIT rooting (D-211).

## Deferred / open debt (all blocked-by/note; none a Phase-11 blocker yet)

- **D-211** GC-on-JIT precise rooting → §11.4 (emit DONE; only rooting deferred, safe per non-moving+no-reclaim).
- **D-210** cross-module frame-consuming TC cohort stack-save (terminating programs correct; not a corpus gap).
- **D-238** x86_64 cross-instance EH thunk parity (arm64 done; FP-walk MOV + RBP variant).
- **D-234** memory64 OOB harness false-report (codegen proven correct 6 paths; runner-side fix).
- **D-242** interp 256-frame call stack too shallow for standard-Go runtime (go_* CallStackExhausted; §11.1 above).
- D-237 spec-runner double-free (harness); D-229/D-231 x86_64 follow-ons (note); D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21, toolchain provisioned).

## Step 0.7 (next resume)

THIS turn = §11.1 D-241 verifier-ceiling fix (`142f0a53`, CODE): root-caused go_* instantiate-fail to the
verifier/validator branch-depth drift (256 vs 1024); shared `zir.max_control_stack` + diff_runner v2-trap
categorisation + D-241 resolved + D-242 filed (interp stack-depth). mac_gate green, 2-arch xc clean. **ubuntu
kick SENT** against `142f0a53` — Step 0.7 next cycle MUST `tail -3 /tmp/ubuntu.log`; RED → revert to `74046364`
(last ubuntu-verified). Next → rust_file_io WASI gap or D-242 frame-stack bundle.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); pick the exe by mtime (bare `head -1` = STALE). `ZWASM_SPEC_ENGINE=jit <exe>
test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Phase 11 adds WASI + bench gates.

## Key refs

- ROADMAP §11 (WASI 0.1 + bench + SIMD gap + GC-rooting). ADR-0128 (Phase 10); ADR-0133 (§10 re-scoped exit);
  ADR-0067 (3-host bench: Mac native + ubuntunote + windowsmini). `debug_jit_auto` skill for JIT dispatch fails.
- Lessons (this session): `2026-06-03-reprobe-blocked-by-barriers-before-scoping` (D-240 + D-210),
  `2026-06-03-jitinstance-test-compiles-for-host-arch`, `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`.
