# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — re-scoped (ADR-0133)** (Phase 9 = DONE 2026-05-24). §10 exit =
  **interp pass=fail=skip=0 (MET) + JIT 0-real-fail + every JIT skip on the forward-ref'd
  deferred-allowlist** (multi-memory-on-JIT→§14, GC-on-JIT-rooting→§11). Raw "JIT skip=0" (ADR-0128)
  was unreachable in-phase; re-scoped autonomously per ADR-0132.
- **LAST code HEAD** (`50e5ecd3`): **JIT tag-identity canon table — 10.E Cause A.** The JIT matched
  try_table catch clauses by raw local tag index, so two tag imports binding the same source tag
  (`(import "test" "e0")` ×2 → idx 0,1) compared `0==1` → no match → trap. Added `ExceptionTable.tag_canon`
  (resolves throw + catch idx to a canonical representative; null/OOB → raw-idx fallback), carried via
  `JitRuntime.tag_canon_ptr/_count` (size 448→464, layout-stable tail), built in `setup.zig` from the import
  section (same (module,name) → collapse later idx onto earlier; only when ≥2 imported tags). The JIT analog
  of interp's `*TagInstance` key (`mvp.catchTagMatches`). **EH JIT dir 31/3 → 32/2, global 793/4 → 794/3,
  skip=0** (`catch-imported-alias` passes). +1 unit test. **GATE TRAP relearned**: corpus exe MUST be picked
  by mtime (`find … -exec ls -t {} + | head -1`) — `head -1` alone returned a STALE binary and masked the
  delta as 0 until caught.
- **Prior governance turn** (`5447cb10`): ADR-0132 (cross-phase ROADMAP re-sequencing now AUTONOMOUS) +
  ADR-0133 (Phase 10 exit re-scope; close-invariant I24; §10-scope RESOLVED, USER-GATED flag retired).
  D-237 (spec-runner double-free, harness-only).
- **Prior (this bundle chain)**: `590093f5` JIT catchless try_table (eh_catch_entries null→empty; unblocked
  try_table.1 compile, +29 EH); `3b668110` JIT tag index space includes imported tags (validator
  StackTypeMismatch); `2b48dfdc`/`74d155b7` D-235 JIT call_indirect subtype. interp wasm-3.0 corpus FULLY
  GREEN. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`; JIT entry = `runner.zig` `JitInstance`.
- **EH-on-JIT dispatch IS wired** (lesson `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`):
  throw_trampoline.zig trampolineCore + zwasmThrowTrampoline (all 3 ABIs) set eh_handler_sp/fp/pc + JMP.
  Its docstring (lines 9-35, "3c-ii deferred") is STALE — fix when next touching. With try_table.1 now
  compiling, the dispatch RUNS — and the 5 fails are real dispatch-correctness bugs (below).
- **Watch**: `runner_test.zig` 1370 / `compile.zig` 1223 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 (WARN, < hard 2000).

## Active task — `10.E-eh-on-jit` bundle: CAUSE B (cross-instance throw)  **NEXT**

try_table.1.wasm runs 34 asserts (32 pass). ✅ Cause A FIXED (`50e5ecd3`, tag-identity canon). The **2
remaining fails are both Cause B** (`catch-imported` got=1, `imported-mismatch` got=1 — confirmed: each
throws a tag owned by module 1 via a cross-instance call):

- **CAUSE B — cross-INSTANCE throw via the bridge thunk. DEEPER (multi-cycle).** `catch-imported` (and the
  separate `imported-mismatch` module) call `test::throw` (module 1) via the D-225 bridge thunk, which swaps
  runtime_ptr to module 1's `*JitRuntime` → the throw runs against module 1's EMPTY exception table → uncaught
  → thunk RETs normally → caller resumes past the call with `i32.const 1` leaked → returns 1 (the catch NEVER
  fires; not a landing-pad reconciliation bug). `unwind.zig:26-31` explicitly defers per-frame-instance
  dispatch. Fix: resolve the thrown tag to its identity at the throw site (throwing instance's tags), then
  FP-walk frames matching identity against EACH frame's OWN instance exception table (per-frame-instance
  dispatch). The Cause-A canon map is per-module local ids (NOT comparable across instances) — Cause B needs a
  GLOBAL identity (source TagInstance ptr / global canonical id) so a module-1 throw matches a module-2 catch.
  In §10.E scope ("cross-module exception propagation"). loci: throw_trampoline.zig trampolineCore (single
  rt/table today), exception_table.zig (tag_canon today local), the D-225 thunk in setup.zig (runtime_ptr swap).

Other non-gated tracks (after EH): **D-234** (memory64 assert_trap harness artifact), **D-198**, **D-209**,
**D-210** (return_call_indirect-in-try = func[36], TC+EH gap). Realworld GC/EH/TC producers.

**§10-scope: RESOLVED** (ADR-0133, this turn) — no longer user-gated. The §10 exit is re-scoped (interp
100% + JIT 0-real-fail + JIT-skip⊆deferred-allowlist). `.dev/phase10_scope_reassessment.md` is now historical
(prep doc; superseded by ADR-0133). Future cross-phase mismatches: re-sequence autonomously per ADR-0132 (no stop).

## Active bundle

- **Bundle-ID**: `10.E-eh-on-jit` (opened `3b668110`).  **Cycles-remaining**: ~1-2 (Cause B only).
- **Continuity-memo**: try_table.1.wasm COMPILES + RUNS, 32/34. ✅ func[6] validate (`3b668110`) → ✅ catchless
  try_table (`590093f5`, +29) → ✅ try_table-result-arity (`881b25e0`, +2) → ✅ **Cause A aliased-import identity
  (`50e5ecd3`, +1)** → ❌ **Cause B cross-INSTANCE throw via bridge thunk (2 fails)** — full plan + loci in Active
  task above. func[36] return_call_indirect-in-try = separate TC+EH gap (D-210 family).
- **Exit-condition**: JIT EH dir return-fail = 0 (currently pass=32 fail=2 skip=0 → target 34/0/0).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 stale u32; D-234 (51 OOB assert_trap = harness artifact).
- **10.R** function-references — corpus green; residual = D-198 + br_on_null/cast modrej (StackTypeMismatch).
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + return_call_indirect-in-try + `wasm_of_ocaml`.
- **10.E** EH — try_table.1 compiles+runs (32/34); blocker = Cause B (2 cross-instance fails) + eh_frequency runner (I20),
  c_api tag accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE; §1 + PHASE C + D-235 DONE; remaining = D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = Cause A (`50e5ecd3`, code). Mac `test-all` + lint gate GREEN. ubuntu kick fired against `50e5ecd3`
(x86_64) — Step 0.7 next resume: `tail -3 /tmp/ubuntu.log`, revert the commit pair on FAIL. Mac aarch64.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); **pick the exe by mtime** — `/usr/bin/find .zig-cache/o -name zwasm-spec-wasm-3-0-assert
-type f -exec ls -t {} + | head -1` (bare `head -1` returns a STALE binary → masks the delta; relearned this turn).
`ZWASM_SPEC_ENGINE=jit <exe> test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Per-dir
`JIT: return pass/fail/skip` + `JITval`/`JITfail`/`JITmodrej`.

## Key refs

- ADR-0128 (Phase 10 100%); ADR-0114 (EH design — try_table/landing pads/trampoline); ADR-0119 (naked trampoline);
  ADR-0131/0126 (subtype + canonical ids, D-235). ROADMAP §10.E. `debug_jit_auto` skill for the dispatch fails.
- Debt: **D-234**, D-198 / D-209 / D-210 / D-211 / D-212.
  Lessons: `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`,
  `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks`, `2026-06-03-jit-trampoline-mid-op-clobbers-operands`.
