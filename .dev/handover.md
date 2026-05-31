# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ⚠ Pending user action — RESTART recommended (clean boundary)

Recommend a session restart so the `survey_budget_guard` hook (`d68e7b7e`) +
`CLAUDE_CODE_DISABLE_1M_CONTEXT=1` 200K pin load fresh at startup. The hook IS
already firing this session (harness applied it live), but a restart re-asserts
the 200K window cleanly. Cycle B just landed green (`c94bd04f`) → this is a clean
commit boundary, the ideal restart point. Clear this section after restart.

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: 10.G br_on_cast/br_on_cast_fail **Cycle B DONE** (`c94bd04f`) — JIT emit both arches:
  peek ref → marshal → CALL `jitGcRefTest` → `branchOnReg` (the Cycle-A `7a44f910` shared 5-case
  core); `_fail` inverts the bool (CMP/CSET · TEST/SETE) first. e2e i31-match→7 green (2237 pass).
  **All GC-op JIT emit now complete on both arches** (i31 + struct/array families + ref.eq +
  ref.test/cast/cast_null + br_on_cast/_fail). Recipe lesson: a peeked-ref vreg that spans the
  op's internal CALL MUST be spill-homed (slot id ≥ max_reg_slots_gpr), else the CALL clobbers
  the caller-saved reg and i31.get_s traps on garbage (regalloc_compute now force-spills both ops).
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`); JIT corpus run = §1. JIT emits
  1.0/2.0 + TC + func-refs + EH + i31 + full struct family + full array family + ref.eq +
  **ref.test/test_null/cast/cast_null + br_on_cast/br_on_cast_fail** (both arches — GC-op emit
  COMPLETE). Green gc/EH corpus = INTERP. Remaining 10.G = §1 JIT-corpus verify + ADR-0127 Phase
  C + D-198 (NOT more emit).
- **ADR-0128 + ADR-0127 both Accepted** — no remaining user gate; loop runs autonomously.
- **Watch**: `src/engine/runner.zig` at 1894 lines (soft-cap WARN; hard cap 2000). Accumulating
  GC-on-JIT `runI32Export` e2e tests — extract them to a `test/` sibling (or add FILE-SIZE-EXEMPT)
  before the next GC e2e chunk would breach 2000 (the gate BLOCKS at 2000).

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128), value-prioritized (NOT §10 table-first):

1. **Spec-corpus JIT execution mode** (§1) — verification backbone: run the official
   testsuite through the JIT (compile-every-fn → JIT-entry invoke → compare; wasmtime
   `tests/wast.rs` pattern) so every JIT gap shows up RED.
2. **GC-on-JIT op emit** (D-211 bundle; §2) — see Active bundle below.
3. **ADR-0127 PHASE C** — cross-`Types` `canonicalEqual`; `gc/type-subtyping` 5→0.
4. Quick wins: **D-209** (lift leftover `>u32` offset check; payload already u64), **D-198**
   (rec-group subtype), **D-210** (cross-module proper-tail-call — arm64 prologue cohort-save).
5. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` / `emcc
   -fwasm-exceptions` / `guile-hoot`.

## Active bundle

- **Bundle-ID**: `10.G-gc-on-jit-IT-1..N`
- **Cycles-remaining**: ~2
- **Continuity-memo**: PROVEN per-GC-op recipe in **`.dev/phase10_g_op_bundle_plan.md`**
  §"GC-on-JIT emit design" + §"array.* sub-bundle" (single source — do NOT re-derive). Verified
  x86_64 facts: pinned rt = R15; SysV args RDI/RSI/RDX(/RCX/R8), ret RAX; emit scratch = R10
  ∉ regalloc pool ({RBX,R12,R13,R14}). **ref ops carry FULL 64-bit values** (funcref ptr /
  i31-tagged / u32 heap offset) — marshal with 64-bit moves (encOrrReg / encMovRR(.q)); ref.cast
  trap-check is 64-bit (encCmpImmX / encTestRR(.q)). dispatch_collector.zig counts are LITERALS —
  bump per op (now arm64=376 / x86_64_ctx=425). Subtype check is SHARED `gcRefMatchesNonNullCore`.
  **Local forward branch** (ref.cast_null CBZ/JZ-skip): patch in-place after the block — arm64
  `std.mem.writeInt(…, encCbz(reg, disp_words))`; x86_64 `inst.patchRel32(buf, at, 6, disp)`.
  **Passthrough-result gotcha** (lesson `2026-05-31-jit-passthrough-result-clobbered-by-call`):
  a result = operand value set BEFORE a CALL the op emits is CLOBBERED (gprStoreSpilled is a
  no-op for reg-homed results) — capture post-CALL from the return reg, or on a no-CALL branch.
- **DONE both arches — GC-op JIT emit COMPLETE**: i31 + struct.{new_default,get,new,set} +
  **array.\* (all 12)** + ref.eq + ref.test/test_null/cast/cast_null + **br_on_cast/br_on_cast_fail
  (`c94bd04f`, Cycle B)**. Per-op SHAs in `git log`. Per-GC-op touch-points (REUSE for any future
  GC op): op-file ×2 + `collected_{arm64_ops,x86_64_ctx_ops}` + bump dispatch_collector.zig count
  LITERALS + `stackEffect` (value ops) + x86_64 `usesRuntimePtr` (R15 CALL ops) + regalloc_compute
  force-spill (CALL ops) + e2e. br_on_cast adds `branchOnRegCtx` (x86_64) + hand-authored-liveness
  entry.zig e2e (peeked ref spanning the CALL MUST be spill-homed: slot id ≥ max_reg_slots_gpr).
- **NEXT (bundle goal met → retarget)**: the GC-op-emit half is done. Remaining 10.G is the **§1
  JIT-corpus verification backbone** (run the official Wasm 3.0 testsuite THROUGH the JIT —
  compile-every-fn → JIT-entry invoke → compare; wasmtime `tests/wast.rs` pattern; this needs the
  br_on/control + GC ops added to `liveness.compute`, deferred till now) + **ADR-0127 Phase C**
  (cross-`Types` `canonicalEqual`; `gc/type-subtyping` 5→0) + **D-198** (rec-group subtype).
- **Exit-condition**: all GC ops emit on both arches ✓ MET (`c94bd04f`). §1 corpus-green is a
  separate workstream — close or re-scope this bundle to §1 next cycle.

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit PARTIAL (D-211): i31 + full struct family + full array family + ref.eq
  + **ref.test/test_null/cast/cast_null** DONE both arches; remaining = br_on_cast/br_on_cast_fail
  + ADR-0127 PHASE C + D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

**Cycle B (br_on_cast/_fail JIT emit, `c94bd04f`) kicked to ubuntu THIS turn** (background
`test-all` against the pushed HEAD). Next `/continue`: `tail -3 /tmp/ubuntu.log` — expect
`[run_remote_ubuntu] OK (HEAD=<Cycle-B chain tip>)`. On FAIL: revert to the last ubuntu-verified
HEAD (`b7672df0` = Cycle A). Mac aarch64 verified green (2237 pass / 0 fail); ubuntu confirms the
x86_64 br_on_cast mirror (the only un-cross-checked half — the emit is by-construction-symmetric).

**Scaffolding this turn (2026-05-31, no src-behaviour delta)**: context-burn lesson +
`survey_budget_guard` hook (+ refinement) + handover. The hook IS firing live this session;
restart re-asserts it + the 200K pin cleanly (see Pending user action above).

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own
them) — parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan); ADR-0116 (RTT 8-deep Cohen display + subtype check);
  ADR-0127 (cross-module func type-identity); ADR-0126 (canonical type ids); ADR-0115 §10
  (non-moving β collector); ADR-0060 (force-spill). ROADMAP §10.
- Debt: **D-211** (GC-on-JIT), D-212 (GC FP-value marshal gap), D-209 (stale), D-202 / D-198 /
  D-210. Lessons `2026-05-31-jit-passthrough-result-clobbered-by-call` +
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` + `...-partial-spec-corpus-interp`.
