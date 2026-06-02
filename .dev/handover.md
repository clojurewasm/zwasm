# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`c5ab78c1`): §1 spec-corpus JIT mode. Session +74: D-223 (+43), D-212 (+6), D-218 (+8),
  D-224 (+11), D-225 ref.func-global (+1) + runner-wiring (+3) + **globals-layout (+1, `c5ab78c1`)**.
  D-225 imported-GLOBAL track COMPLETE: ref.func-global (`181f2f2b`) + table init-expr (`36904b47`) +
  setup-time const-expr resolution (`e03c2aee`) + runner wiring (`a6cfd65e`, flips i31.3) + **import-
  inclusive globals_buf** (`c5ab78c1`: emitted-code global layout is imports-first; globals_buf was
  defined-only → emitted `global.get $defined` read OOB; now sized num_global_imports+globals_count,
  flips i31.4 + fixes emitted global.get-of-import). Opt-in `ZWASM_SPEC_ENGINE=jit`. Mac aarch64:
  **pass=568 fail=11 skip=716** (memory64 GREEN; interp UNCHANGED, jit_mode-guarded).
  **fail taxonomy (11)**: gc/array ×6 (corpus-context-dependent traps), ref_func call-f/call-v ×3
  (cross-module FUNC dispatch — the remaining D-225 lever), gc/type-subtyping ×1 (ADR-0127 PHASE C),
  try_table ×1 (EH).
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

- **Bundle-ID**: `10.G-§1-cross-module-jit-imports` (D-225; the §1 backbone is long-operational at
  pass=564 — this sub-bundle is the current multi-cycle integration).
- **Cycles-remaining**: ~2 (architectural — cross-module FUNC dispatch)
- **Continuity-memo**: imported-GLOBAL track DONE (i31.3 `a6cfd65e` + i31.4 `c5ab78c1`; setup-time
  const-expr + runner wiring + import-inclusive globals_buf). **NEXT = cross-module FUNC dispatch**
  (ref_func call-f/call-v ×3). The §1 JIT path compiles each module standalone (`JitInstance.initLinked`,
  `runner.zig`); an imported FUNC's `dispatch[N]` slot = `hostDispatchTrap` → call traps. PLAN (survey
  `private/notes/d225-cross-module-jit-survey.md`): populate `dispatch[N]` with the EXPORTER's JIT entry
  ptr (C-ABI symmetric, no stack marshal) — but the runner creates each `JitInstance` standalone, so the
  exporter's JIT entry isn't kept. Either (a) the runner keeps registered exporter `JitInstance`s alive +
  threads their per-func entry ptrs into the importer's `initLinked` (parallels `jitResolveImportedGlobals`
  but for funcs — needs an exporter→funcptr accessor on JitInstance), or (b) a host-thunk that re-enters
  the exporter instance. Start: read how `dispatch`/`host_dispatch_base`/`populateDispatch` (setup.zig:~225)
  wires imported funcs + what `hostDispatchTrap` does. Likely 2-cycle.
- **Exit-condition**: ref_func `call-f` OR `call-v` flips green (cross-module FUNC call dispatches to
  exporter, no trap).
- **NEXT chunk** = **cross-module FUNC dispatch** (ref_func call-f/call-v ×3; see bundle Continuity-memo).
  The remaining D-225 architectural lever now that the imported-GLOBAL track is complete.
  - **The other 8**: gc/array ×6 = CORPUS-CONTEXT-DEPENDENT traps (array.5 `new` works standalone;
    `get` takes a ref arg → repro needs the corpus sequence + the fnv-fingerprint/non-zero-probe
    method from lesson `jit-result-bug-stale-register-confound`); gc/type-subtyping ×1 = ADR-0127
    PHASE C (Proposed, user-Accept-gated + regression-risky); try_table ×1 = EH. Skip multi-memory 51 (Phase-14).
  - **REALITY**: big levers SPENT (+74 this session); the tail is architectural (cross-module FUNC) or
    context-dependent — expect lower per-turn corpus throughput; each is a deliberate focused bundle.

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

Prior turn ubuntu GREEN (`tail -3 /tmp/ubuntu.log` = `OK (HEAD=4344c8b5)`). THIS turn landed the JIT
import-inclusive globals_buf fix (`c5ab78c1`: src/engine/setup.zig; Mac gate test+lint OK) → ubuntu
`test-all` kicked at end → `tail -3 /tmp/ubuntu.log` next resume (Step 0.7). On FAIL revert to
`4344c8b5`. Mac aarch64; ubuntu = x86_64.

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
