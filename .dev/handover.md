# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`fa596f08`): §1 spec-corpus JIT mode. **D-225 cross-module imports COMPLETE** (globals +
  funcs) + **gc/array CLUSTER RESOLVED** (`fa596f08`, +6): the JIT setup now evals GC general const-expr
  element-segment items (`array.new`/`struct.new`/`ref.func` in `seg.item_exprs`) via evalGlobalInitGc →
  `elem_refs`, so `array.new_elem` (gc/array.8) reads real refs instead of an empty (seg_len=0) segment →
  trap. Opt-in `ZWASM_SPEC_ENGINE=jit`. Mac aarch64: **pass=577 fail=2 skip=716** (memory64 GREEN; interp
  UNCHANGED, jit_mode-guarded). **The JIT-EXECUTED fail count is now 2** — both gated/deep:
  gc/type-subtyping ×1 (ADR-0127 PHASE C, **user-Accept-gated**) + try_table ×1 (EH-on-JIT gap).
  **skip=716 is the larger remaining §10 lever** (JIT-ineligible shapes: args>elig / v128 / multi-value /
  void / cross-module-CALL-not-in-eligible-subset / compile-rejected [multi-memory Phase-14 / unemitted-op
  / validate gap]). ADR-0128 §10 exit needs pass=fail=skip=0 both backends → skip-reduction is the bulk.
- **PER-MODULE blocker-STACK reality** (lesson `2026-06-02-jit-corpus-late-phase-is-per-module-
  blocker-stacks`): since memory64 (+208, last big mover), every gc/funcref fix has been correct
  but ~0 corpus — each remaining module has 3-6 DISTINCT blockers; JIT rejects at the FIRST
  (`JITmodrej`), so a module flips only when its LAST clears. Big levers are SPENT. Remaining
  reject causes: MultipleMemories 51 (Phase-14 deferred), InvalidGlobalInitExpr 9 (struct.new/
  array.new const-expr — heap alloc), UnsupportedOp 7 (any.convert_extern needs EMIT),
  StackTypeMismatch 6 (funcref br_on_null validator gap), UnsupportedEntrySignature 7, InvalidFuncIndex 4.
- **Two paths**: spec corpus = interp by default; JIT is opt-in `ZWASM_SPEC_ENGINE=jit` (default
  test-all unchanged). JIT entry = `runner.zig` `JitInstance`. ADR-0128 + ADR-0127 Accepted (no user gate).
- **Watch**: `runner_test.zig` 1180 (gc tests extracted → `runner_gc_test.zig`, `99e122e1`). Headroom OK.

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

- **Bundle-ID**: `10.G-§1-skip-reduction` (prior gc/array bundle CLOSED at `fa596f08`, exit met: array.8
  green, pass=577; JIT-executed fails now 2, both gated/deep).
- **Cycles-remaining**: ~2 (skip-reduction — verify-PASS not just compile)
- **Continuity-memo**: §1 JIT-EXECUTED fails = 2 (type-subtyping user-gated ADR-0127 PHASE C; try_table
  EH-on-JIT). Remaining §10 exit bulk = **skip=716**. TAXONOMY: JITmodrej = MultipleMemories 51 (Phase-14,
  untouchable), UnsupportedOp 10, UnsupportedEntrySignature 7, StackTypeMismatch 6, +3. Eligibility-gated =
  ref-arg ×34 (hard), multi-value ×19. **TWO COURSE-CORRECTIONS this cycle (both reverted, net-zero code,
  corpus stays 577/2):** (1) **multi-value NOT clean** — needs `buffer_write` ABI but `compileWasm` hardcodes
  `.register_write` (compile.zig:1058) + register dispatch helpers depend on it → full D-094/D-164 migration,
  MAJOR, defer. (2) **`any.convert_extern`/`extern.convert_any` emit is trivial** (identity passthrough:
  codegen no-op pop+push + stack-effect 1→1 in liveness_stack_effect.zig + register in dispatch_collector_ops
  + counts arm64 378→380 / ctx_ops 427→429) — BUT it's used across MANY gc modules; enabling it unblocked ~89
  asserts = +50 pass BUT **+39 FAIL** (32 gc/ref_test JITval mismatches + 7 gc/ref_cast traps): `ref.test`/
  `ref.cast` on a convert-wrapped extern/any ref mis-executes (nontrivial RTT semantics). **LESSON: unblocking
  a modrej module ≠ passing it** — a skip→fail trade worsens the metric. So convert must bundle WITH the
  ref.test/ref.cast-on-extern RTT fix (verify the 32+7 PASS), not ship alone. **NEXT (pick a CLEAN lever)**:
  for any UnsupportedOp module, first check its asserts would PASS once it compiles (disasm + reason about the
  ops' runtime semantics) — prefer modules whose remaining ops are value-simple (e.g. tail-call/
  return_call_indirect.0, function-references/br_on_null.1) over GC-RTT-entangled ones (ref_test/ref_cast/
  br_on_cast/extern). Method: disasm via the python `fb`-opcode scan; the convert emit recipe above is proven
  (re-apply when doing the convert+RTT bundle). try_table + type-subtyping unchanged.
- **Exit-condition**: ≥1 UnsupportedOp module flips modrej→compiles AND its asserts PASS (net fail unchanged).

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

Prior turn ubuntu GREEN (`OK (HEAD=09777262)` — pass=577 remote-verified). THIS turn = skip-reduction
investigation: tried convert-op emit + multi-value, both REVERTED (net-zero code; corpus stays 577/2) —
convert-alone caused +39 fail (skip→fail), multi-value needs the buffer_write ABI migration. Memo updated
with both course-corrections + the "verify-PASS-not-compile" lesson. No ubuntu kick (docs-only, HEAD
unchanged = 09777262). Next resume: pick a CLEAN UnsupportedOp lever per the memo. Mac aarch64; ubuntu = x86_64.

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
