# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`24a17ed7`): **gc/type-subtyping.17 "run" CLOSED** (`80aeee1d` + `24a17ed7` guard test) — two
  coordinated interp fixes (the cyc180/D-198 rabbit hole): #1 call_indirect/return_call_indirect accept a
  callee whose declared type is a SUBTYPE of the call type (Wasm §3.3.5.5, gti-gated concreteReaches); #2
  function-level `br` (depth==label_len) returns via returnFromFunction (Wasm §4.4.8 implicit outermost
  block) instead of trapping. **interp assert_return now fully green (1233/0)**; no regression (gate green).
- **⚠ USER-DIRECTED STOP** (no re-arm). Two audits PREPPED for fresh deep sessions (wiring/reference chains):
  (1) **`.dev/wasm_level_separation_audit.md`** — the user's PRIMARY axis: is wasm 1.0/2.0/3.0 separation
  real or "half規約頼み"? CONFIRMED leak: mvp.zig registers handlers unconditionally + inlines 3.0 logic
  (br_on_cast, call_indirect-subtype) NOT per-op-DCE'd → contradicts ADR-0073's "absent from v1_0 binary";
  dispatch_consistency_audit (shape-only) can't catch it. (2) **`.dev/phase10_scope_reassessment.md`** —
  §10 exit vs Phase-14 deferral, reframed as ROADMAP RE-STRUCTURING (multi-memory = first instance; enumerate
  all deferred-but-§10-gating items + re-sequence phases, not a one-off ADR-0128 footnote).
- **PRIOR**: ADR-0127 PHASE C DONE (cross-module type-def identity; assert_unlinkable 4→0; predicates
  `canonicalEqualCross` `6f1eeb4a` + `superReachesCross` `d5183d4e` + integration `add983e8`). multi-value +18.
- **wasm-3.0 interp fails now = 4** (was 5): all gc/type-subtyping **assert_trap** (NOT .17 — other modules;
  possibly the runner's "assert_trap class discrimination" limitation). `8d5d67ed` fixed a SEPARATE bug — .12/.14 globals wrongly rejected
  (concrete-ref subtype reached supers by index, missed cross-rec-group canonical equality; now
  `gcConcreteReachesCanonical`). The 5 asserts are unmoved — they're RUNTIME (see bundle NEXT). JIT 762/2/531.
- **Recent fixes (detail in debt.yaml)**: **D-228** (`7bb3699a`) test-all now runs the wasm_3_0 unit tests
  (was `zig build test`-only → a stale assert false-greened both hosts). **D-229** (`a5f6b238`) param-bearing
  e2e test gated to aarch64 (x86_64 SysV thunk lacks params; low-ROI follow-on).
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

- **Bundle-ID**: `10.G-typesubtyping-RTT` (prior `10.G-typesubtyping-PHASE-C` CLOSED — exit met: assert_unlinkable
  fail 4→0, no regression. ADR-0127 PHASE C: predicates `canonicalEqualCross`+`superReachesCross` + linker
  integration `add983e8`. Earlier this bundle-chain: §1 multi-value +18).
- **Cycles-remaining**: ~1. DONE this bundle: .12/.14 global-init canonical-subtype (`8d5d67ed`) +
  **.17 "run" CLOSED** (`80aeee1d` call_indirect-subtype + function-level-br, `24a17ed7` guard test) — the
  cyc180/D-198 rabbit hole (2 coordinated interp fixes: root cause #2 was function-level `br 0` trapping
  instead of returning). interp assert_return fully green (1233/0).
- **REMAINING**: (a) **4 interp assert_trap fails** — other gc/type-subtyping modules (NOT .17); likely the
  runner's "assert_trap class discrimination" limitation (verify which modules + runner-side vs interp).
  (b) **§10-scope question** → prepped in **`.dev/phase10_scope_reassessment.md`** (USER asked for a fresh
  deep session; reference chain + 4 decision points there). (c) JIT eh/try_table (EH-on-JIT, deep) + re-check
  JIT gc/type-subtyping (the .17 fix is interp-only; the JIT path may still need the same subtype/br fixes).
- **Continuity-memo**: interp fails 4 (gc/type-subtyping assert_trap). JIT 762/2/531. PHASE C follow-ups
  (debt-worthy, non-blocking): api/instance.zig:572 + instantiate.zig:1657 `.cross_module` still structural-
  only; wasm-3.0 runner reports-not-gates on fails.
- **Exit-condition**: resolve the §10-scope question (ADR-0128 amend or hold) + drive the 4 trap_fails to a
  measured floor. Then bundle CLOSES.

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE both arches; §1 JIT-corpus + ADR-0127 PHASE C (unlinkable) DONE;
  remaining = gc/type-subtyping RTT fails (this bundle) + D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = RTT cycle 4: FIXED .17 "run" (call_indirect-subtype + function-level-br, `80aeee1d` + guard test
`24a17ed7`) — interp assert_return fully green; fixed a gate regression (concreteReaches must be gti-gated,
no raw sub==target shortcut). Then per USER directive, prepped the §10-scope question for a fresh deep
session: **`.dev/phase10_scope_reassessment.md`**. **USER-DIRECTED STOP — loop NOT re-armed this turn.**
ubuntu kick fired for the interp-core .17 fix (cross-host verify). Next resume Step 0.7: `tail -3
/tmp/ubuntu.log` — expect `OK (HEAD=<final-SHA>)`; on FAIL revert to add983e8 (the last verified pre-RTT-code
HEAD). The next session is the §10-scope deep dive (read phase10_scope_reassessment.md first). Mac aarch64; ubuntu = x86_64.

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
