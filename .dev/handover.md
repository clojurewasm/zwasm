# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`6f1eeb4a`): on **ADR-0127 PHASE C** (cross-module func-import type-identity; closes the 4
  `gc/type-subtyping.{36,42,52,54}` assert_unlinkable fails, both backends). Cycle 1 DONE:
  `sections.canonicalEqualCross` (cross-`Types` iso-recursive type-def equality) + 4 unit tests, isolated/
  unwired. Prior: multi-value JIT invoke +18 → corpus **762/2/531** (DONE). full wasm-3.0 interp fail tally
  = 9 (1 return + 4 trap + 4 unlinkable); PHASE C closes the 4 unlinkable.
- **Two gate/portability fixes this stretch**: **D-228** (`7bb3699a`) — `test-all` didn't run the wasm_3_0
  unit tests (only `zig build test` did) → chunk-2's stale `jitReturnEligible` assert false-greened on BOTH
  hosts; now `test_all_step.dependOn` both unit artifacts. **D-229** (`a5f6b238`) — the param-bearing e2e
  test errored on x86_64 (SysV `wrapper_thunk.emit` rejects params; only arm64 AAPCS + Win64 do them) →
  gated the test to aarch64; x86_64 SysV param-bearing thunk is low-ROI follow-on debt. Lesson: a feature
  added on one arch + an all-arch e2e test = ubuntu red; gate the test per-arch OR implement both arches.
- **PER-MODULE blocker-STACK reality** (lesson `2026-06-02-jit-corpus-late-phase-is-per-module-
  blocker-stacks`): since memory64 (+208, last big mover), every gc/funcref fix has been correct
  but ~0 corpus — each remaining module has 3-6 DISTINCT blockers; JIT rejects at the FIRST
  (`JITmodrej`), so a module flips only when its LAST clears. Big levers are SPENT. Remaining
  reject causes: MultipleMemories 51 (Phase-14 deferred), InvalidGlobalInitExpr 9 (struct.new/
  array.new const-expr — heap alloc), UnsupportedOp 7 (any.convert_extern needs EMIT),
  StackTypeMismatch 6 (funcref br_on_null validator gap), UnsupportedEntrySignature 7, InvalidFuncIndex 4.
- **Two paths**: spec corpus = interp by default; JIT is opt-in `ZWASM_SPEC_ENGINE=jit` (default
  test-all unchanged). JIT entry = `runner.zig` `JitInstance`. ADR-0128 + ADR-0127 Accepted (no user gate).
- **Watch**: `runner_test.zig` 1264 (gc tests extracted → `runner_gc_test.zig`). Over soft 1000 WARN, under hard 2000.

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128), value-prioritized (NOT §10 table-first):

1. **Spec-corpus JIT execution mode** (§1) — verification backbone — **NOW (Active bundle)**.
2. GC-on-JIT op emit (§2) — **DONE both arches**.
3. **ADR-0127 PHASE C** — cross-`Types` `canonicalEqual`; `gc/type-subtyping` 5→0.
4. Quick wins: **D-209** (lift leftover `>u32` offset check; payload already u64), **D-198**
   (rec-group subtype), **D-210** (cross-module proper-tail-call — arm64 prologue cohort-save).
5. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` / `emcc
   -fwasm-exceptions` / `guile-hoot`.

## Active bundle

- **Bundle-ID**: `10.G-typesubtyping-PHASE-C` (prior `10.G-§1-multivalue` CLOSED — multi-value invoke +
  arm64 1-param thunk delivered +18 → 762/2/531; the §1 skip tail is now its non-deferred floor: residual
  skip=531 dominated by multi-memory 407 = Phase-14-deferred. Multi-value follow-ons are low-ROI: x86_64
  SysV param-bearing = D-229, 2/3-param/FP-result arm64 = unmeasured-but-marginal).
- **Cycles-remaining**: ~1-2. Cycle-1 survey DONE; cycle-2 `canonicalEqualCross` predicate DONE (`6f1eeb4a`,
  4 tests). NEXT = the wiring chunk (thread exporter type-def + run PHASE C #2 at resolve).
- **PIVOT RATIONALE**: §1 corpus skip-reduction is exhausted; the binding §10 exit constraint is now
  **fail=0 both backends**, currently fail=2. ADR-0127 PHASE C closes ONE real JIT-executed fail
  (gc/type-subtyping). ADR-0127 is **Accepted** (via ADR-0128 100% directive — autonomous, NOT user-gated;
  "D-202 PHASE C implements next"). This is higher value than more §1 skip-shaving.
- **SURVEY DONE (`c5c547d1`)** — SCOPE CORRECTION: PHASE C targets the **4 assert_unlinkable fails**
  `gc/type-subtyping.{36,42,52,54}` (importer imports open `(sub (func))`, exporter provides structurally-
  identical but canonically-DISTINCT type-def → currently WRONGLY links). NOT the assert_return run-Trap
  (separate RTT mechanism, still fail). PHASE A (structural subtyping) + B (finality) landed (cyc236/239).
  PHASE C adds **type-definition identity**: canonical-equal OR declared-supertype-reach across the two
  modules' `Types`. `funcTypeImportCompatible` (validator.zig:3155) does structural-only today.
- **IMPL PLAN**: (1) ✅ DONE `6f1eeb4a` — `sections.canonicalEqualCross` predicate + 4 tests. (2) NEXT —
  thread exporter type-def through `CrossModuleFuncEntry` (linker.zig:130, currently `{source_signature,
  source_final}`) + `ExportFuncType` (instantiate buildExportTypes:613). PHASE C #2 = canonicalEqualCross
  OR exporter declares importer's type-def in its supertype chain. **LIFETIME CONCERN**: canonicalEqualCross
  needs the exporter's FULL `Types` alive at resolve to recurse nested refs; buildExportTypes currently frees
  the parse-time Types after capturing {sig,final}. The corpus targets (`.36` etc.) are `()->()` with NO
  nested concrete refs → threading {typeidx, finals, supertypes-as-indices} may suffice WITHOUT keeping the
  full Types (canonicalEqualCross degenerates to finality+structure for ref-free defs). Decide chunk-2: thin
  thread (corpus-sufficient) vs full Types retention (general). (3) run #2 at linker resolve (linker.zig:482)
  + instantiate checkImportTypeMatches (:1657). Start chunk-2 with the smallest red: a 2-module test where
  importer's open `(sub (func))` vs exporter's distinct def → link REJECTS (currently wrongly accepts).
- **Continuity-memo**: full wasm-3.0 fail tally (ubuntu interp): assert_return fail=1 + assert_trap fail=4
  + assert_unlinkable fail=4 = 9 (both backends share linking/validation fails). PHASE C closes the 4
  unlinkable. JIT corpus = **762/2/531**. See D-202 (PHASE A/B landed, C scope).
- **Exit-condition**: `gc/type-subtyping.{36,42,52,54}` assert_unlinkable PASS (fail 4→0 both backends), NO
  regression in the 441 exact-equal cross-module imports (407 multi-mem + 34 EH — canonically equal, must
  still link). Risk: PHASE C NARROWS acceptance; the green cross-module corpus is the net.

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE both arches; remaining = §1 JIT-corpus mode (this bundle)
  + ADR-0127 PHASE C + D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = ADR-0127 PHASE C cycle 1: `sections.canonicalEqualCross` predicate + 4 unit tests (`6f1eeb4a`),
isolated/unwired (zero regression risk). Mac-green (mac_gate test-all + lint). Next resume Step 0.7:
`tail -3 /tmp/ubuntu.log` — expect `OK (HEAD=6f1eeb4a)`; on FAIL revert to the last ubuntu-verified HEAD
(a5f6b238 was the prior confirmed OK). Then start the WIRING chunk (thread exporter type-def + run PHASE C
#2 acceptance at linker resolve / checkImportTypeMatches — see Active bundle IMPL PLAN). Mac aarch64; ubuntu = x86_64.

**Gate hygiene (NEW, `2134116b`)**: use `bash scripts/mac_gate.sh` for the Step-5 Mac gate —
never `zig build test-all > log; grep -c … log` (trailing `grep -c` exits 1 on zero matches →
false "command failed" notification on a green build). Inspect via `$MAC_GATE_LOG` separately.

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own
them) — the parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan; §1 = spec-corpus JIT execution mode); ADR-0116
  (RTT 8-deep Cohen display + subtype check); ADR-0127 (cross-module func type-identity);
  ADR-0126 (canonical type ids); ADR-0115 §10 (non-moving β collector); ADR-0060 (force-spill).
  ROADMAP §10.
- Debt: **D-211** (GC-on-JIT — emit done; §1 verifies it), D-212 (GC FP-value marshal gap —
  surfaces under §1 mode), D-209 (stale), D-202 / D-198 / D-210. Lessons
  `2026-05-31-spec-jit-corpus-fails-are-gaps-not-stale-state` (this turn — measure the fail
  taxonomy before building the mechanism a narrative assumed) +
  `2026-05-31-jit-passthrough-result-clobbered-by-call` +
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` +
  `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp`.
