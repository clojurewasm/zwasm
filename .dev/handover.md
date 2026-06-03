# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 = DONE 2026-06-03). Phase 10 (Wasm 3.0:
  GC + EH + tail-call + memory64 + function-references + multi-memory) CLOSED this turn per the ADR-0133
  re-scoped exit: interp pass=fail=skip=0 + JIT 0-real-fail + every JIT skip/modrej on the deferred-allowlist.
- **PHASE 10 CLOSE** (this turn): `check_phase10_close_invariants.sh` = **16 PASS / 9 SKIP / 0 FAIL**. Flipped
  all six §10 rows (10.M/R/TC/E/G/P) `[x]` + widget Phase 10 → DONE + Phase 11 → IN-PROGRESS + opened §11 task
  table. Mandatory `audit_scaffolding` ran clean (no block; fixed 2 stale debt heads D-211/D-234 + reclassified
  D-204/D-209; report `private/audit-2026-06-03.md`).
- **JIT corpus final** (`dbcfff1b`, ubuntu-verified `eba86890`): memory64 336/1(D-234 harness)/0, tail-call
  71/0/0, EH 34/0/0, gc 402/0/5, function-references 36/0/3, multi-memory 0/0/407(→§14). All skips = eligibility-
  gate; all 59 modrej = multi-memory. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`.
- **GATE TRAP** (still live): JIT corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare
  `head -1` = STALE binary → masks the delta.
- **Watch**: `runner_test.zig` ~1490 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 / `validator.zig` 3204 (cap 3300, D-204) — all < hard 2000/3300.

## Active task — Phase 11 start + deferred §10 close-hygiene  **NEXT**

Two immediate close-hygiene follow-ons (do FIRST next cycle, then dive into §11):
1. **§10 SHA backfill** — the six §10 rows + this session's §10 work carry bare/`[x]` SHAs; batch-backfill via
   `git log --grep="§9.10 / 10.X"` per row → one `chore(p10): backfill §10 SHA pointers` commit. (Deferred from
   the close turn to keep it focused.)
2. **windowsmini phase-boundary reconciliation** — DEFERRED per user policy (autonomous loop skips windowsmini +
   batch-resolves). Note only; don't block §11.

Then **§11 work** (ROADMAP §11 task table). Suggested first chunk = **11.1 WASI 0.1** — Step-0 survey the current
preview1 syscall surface vs the realworld SKIP-WASI gaps (the ubuntu run skipped `go_math_big` = instantiate
error / WASI host gap). Smallest red = a failing realworld WASI fixture or a missing preview1 syscall. Alt
first chunks: 11.2 bench auto-record, 11.4 GC-on-JIT rooting (D-211, deferred-from-§10 allowlist).

## Deferred / open debt (all blocked-by/note; none a Phase-11 blocker yet)

- **D-211** GC-on-JIT precise rooting → §11.4 (emit DONE; only rooting deferred, safe per non-moving+no-reclaim).
- **D-210** cross-module frame-consuming TC cohort stack-save (terminating programs correct; not a corpus gap).
- **D-238** x86_64 cross-instance EH thunk parity (arm64 done; FP-walk MOV + RBP variant).
- **D-234** memory64 OOB harness false-report (codegen proven correct 6 paths; runner-side fix).
- D-237 spec-runner double-free (harness); D-229/D-231 x86_64 follow-ons (note); D-204/D-209/D-213 (note).
- realworld GC/EH/TC producers (dart/hoot/wasm_of_ocaml/emscripten_eh — I21, toolchain provisioned).

## Step 0.7 (next resume)

THIS turn = **Phase 10 CLOSED** (audited): mandatory audit_scaffolding clean → flipped 6 §10 rows + widget +
opened §11. DOCS/ROADMAP-only (no code) → NO ubuntu kick; Step 0.7 next cycle = nothing to verify (prior code
`dbcfff1b` already ubuntu-OK at `eba86890`). Next → §10 SHA backfill, then §11.1 WASI Step-0 survey.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); pick the exe by mtime (bare `head -1` = STALE). `ZWASM_SPEC_ENGINE=jit <exe>
test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Phase 11 adds WASI + bench gates.

## Key refs

- ROADMAP §11 (WASI 0.1 + bench + SIMD gap + GC-rooting). ADR-0128 (Phase 10); ADR-0133 (§10 re-scoped exit);
  ADR-0067 (3-host bench: Mac native + ubuntunote + windowsmini). `debug_jit_auto` skill for JIT dispatch fails.
- Lessons (this session): `2026-06-03-reprobe-blocked-by-barriers-before-scoping` (D-240 + D-210),
  `2026-06-03-jitinstance-test-compiles-for-host-arch`, `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`.
