# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`add983e8`): **ADR-0127 PHASE C DONE** — cross-module func-import type-def identity. Predicates
  `canonicalEqualCross` (`6f1eeb4a`) + `superReachesCross` (`d5183d4e`); integration (`add983e8`) wires them
  at linker resolve via retained exporter `Types` (Instance arena) + `ExportFuncType.typeidx` +
  `CrossModuleFuncEntry` threading. **wasm-3.0 assert_unlinkable fail 4→0** (gc/type-subtyping.{36,42,52,54};
  no regression — 407 multi-mem + 34 EH + .30/M super-chain stay green). Prior: multi-value JIT invoke +18.
- **wasm-3.0 interp fail tally = 5**: assert_return fail=1 + assert_trap fail=4, all gc/type-subtyping
  (RTT mechanism). `8d5d67ed` fixed a SEPARATE gc/type-subtyping bug — .12/.14 globals wrongly rejected
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
- **Cycles-remaining**: ~1-2. Cycle-1 investigation DONE — root located.
- **ROOT (the 5 asserts)**: ONE module (`.wast:229`) with a SELF-RECURSIVE rec-group chain — `$t0 (func
  (result (ref null func)))`, `$t1 (sub $t0 (func (result (ref null $t1))))`, `$t2 (sub $t1 (func (result
  (ref null $t2))))`. `(invoke "run")` (assert_return fail=1) does 6 `call_indirect (type $tN)` + 6
  `ref.cast (ref $tN)` against a `funcref` table `[$f0:$t0,$f1:$t1,$f2:$t2]` that should ALL succeed
  (subtype calls/casts); `fail1-6` (assert_trap, 4 failing) call_indirect/ref.cast that should TRAP. So the
  fails are RUNTIME `call_indirect` sig-match + `ref.cast` subtype on SELF-RECURSIVE func types — too-strict
  (run traps) and/or too-lax (some fail* don't trap).
- **NEXT (cycle 2)**: find the runtime call_indirect type-match + ref.cast subtype-check sites (likely
  `feature/gc/type_info.zig` canonical_ids + the runtime sig-match in interp/JIT call_indirect); verify they
  compare self-recursive func types by canonical id / iso-recursive equality, not raw index. Smallest red:
  a fixture invoking `run` (must not trap) + a `fail*` (must trap). Cohen-display depth (ADR-0116) +
  canonical-id (ADR-0126) are the relevant machinery. Decide tractability → fix or debt-row if deep.
- **ALSO OPEN (lower priority, follow-ups)**: PHASE C wired only the **linker path** (corpus). The
  api/instance.zig:572 + instantiate.zig:1657 `.cross_module` paths still do structural-only — a C-API
  cross-module import with distinct type-defs wouldn't reject. Not corpus-exercised → debt-worthy, not §10-
  blocking. Also: the wasm-3.0 runner doesn't GATE on its fails (reports only) — a regression in the now-green
  unlinkable wouldn't break the gate; gating becomes possible once all its fails reach 0 (the §10 close goal).
- **Continuity-memo**: wasm-3.0 interp fails now 5 (1 return + 4 trap, all gc/type-subtyping RTT). JIT corpus
  762/2/531; the 2 JIT-executed assert_return fails = gc/type-subtyping (this RTT) + eh/try_table (EH-on-JIT).
- **Exit-condition**: gc/type-subtyping assert_trap fail 4→lower + assert_return fail 1→0 (or a documented
  blocker if the RTT gap is deep/deferred). No regression elsewhere.

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

THIS turn = (PHASE C add983e8 ubuntu-verified OK) + RTT cycle 1: fixed gc/type-subtyping.12/.14 global-init
canonical-subtype rejection (`8d5d67ed`) + investigated the 5 RTT asserts → root = runtime call_indirect/
ref.cast subtype on self-recursive func types (.wast:229 module). Mac-green (test-all + lint). Next resume
Step 0.7: `tail -3 /tmp/ubuntu.log` — expect `OK (HEAD=8d5d67ed)`; on FAIL revert to last verified HEAD
(add983e8). Then cycle 2 per Active-bundle NEXT (runtime self-recursive call_indirect/ref.cast subtype).
Mac aarch64; ubuntu = x86_64.

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
