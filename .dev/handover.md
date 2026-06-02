# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`d041e425`): **interp wasm-3.0 corpus FULLY GREEN** — D-232 CLOSED (ADR-0131). assert_return
  1233/0, **assert_trap 562/0** (was 558/4), invalid 194/0, unlinkable 8/0, malformed 3/0, exception 4/0.
  Root: `gc_type_infos` was gated on `needs_gc_heap` (struct/array) → func-only `sub`/`final` modules got no
  type-identity table → `concreteReaches` blind → `sigEq` accepted structurally-equal-but-distinct types. Fix:
  materialise gti when `needs_gc_heap` OR `usesTypeSubtyping` (any non-final OR declared super; ADR-0115 zero-
  overhead kept via a `sub`-form byte pre-filter) + `concreteReaches` authoritative over `sigEq` when gti
  present. +3 unit tests. Mac test-all green. Lesson `2026-06-02-gti-tied-to-heap-need-misses-func-subtyping`.
- **PRIOR THIS SESSION**: level-sep PRIMARY-axis audit FULLY FIXED (ADR-0130, D-230): interp+arm64 3.0 leaks
  comptime-gated, DCE gate revived into `gate_merge.sh`, all 6 `-Dwasm×-Dwasi` combos clean. D-231 = x86_64-side
  gate-coverage follow-on. ADR-0127 PHASE C (cross-module type-id; assert_unlinkable 4→0).
- **STILL PREPPED (not yet run)**: **`.dev/phase10_scope_reassessment.md`** — §10 exit vs Phase-14 deferral,
  reframed as ROADMAP RE-STRUCTURING (multi-memory = first instance). USER-flagged; ADR-0128-amendment =
  user-flip case. **The bundle's last open item.** JIT 762/2/531 (interp now 0-fail).
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
- **REMAINING**: (a) **4 interp assert_trap fails — FIXED ✓** (D-232 / ADR-0131, `d041e425`): gti materialised
  for func-subtyping + concreteReaches authoritative. interp corpus FULLY GREEN. (b) **§10-scope question** →
  `.dev/phase10_scope_reassessment.md` (USER-flagged; ADR-0128-amendment = user-flip case) — **the bundle's LAST
  open item; user-gated.** (c) **JIT corpus audited.** jit-mode assert_trap now tests the JIT (D-233
  `1d7f25ea`). Of the 55 assert_trap fails: **51 memory64 = harness artifacts** (mem64 OOB proven correct via 5
  isolated paths, D-234); **4 gc/type-subtyping = REAL** (cyc-5 correction: the JIT canonical is
  D-111 STRUCTURAL `funcTypeEql`, finality-BLIND → `$t1=(sub (func))`/`$t2=(sub final (func))` get the SAME
  canonical → CMP wrongly ACCEPTS fail1/fail2). Plus the gc/type-subtyping `"run"` RETURN-fail (D-111 also
  subtype-BLIND → wrongly TRAPS a legit subtype). **Both = ONE root cause: JIT call_indirect uses D-111
  structural equality, not the gti subtype check (the interp uses gti per D-232).** Full fix → **D-235**
  (gti-canonical in typeidx_base when gti present + subtype trampoline on mismatch; closes 4 gc trap + 1
  return). Other return fail = eh/try_table (EH-on-JIT, separate). assert_RETURN 762/2/531.
- **Continuity-memo**: interp wasm-3.0 = 0 fails (fully green). JIT 762/2/531. PHASE C follow-ups (debt-worthy):
  api/instance.zig:572 + instantiate.zig:1657 `.cross_module` structural-only. This session CLOSED: D-230 (level-
  sep leak + DCE gate revive, ADR-0130) + D-232 (gti func-subtyping, ADR-0131). D-231 = x86_64 DCE-gate follow-on.
- **Exit-condition**: 4 trap_fails → 0 ✓ DONE (D-232/ADR-0131; interp corpus fully green). ONLY the §10-scope
  question remains (USER-flip case, prepped doc) — user-gated. Bundle CLOSES once §10-scope resolved; meanwhile
  non-gated forward work = JIT eh/try_table + re-check JIT gc/type-subtyping (interp fixes are interp-only).

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
