# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: 10.G br_on_cast **Cycle A** — extracted `branchOnReg` from `emitBrIf` both arches
  (`7a44f910`, behaviour-neutral; br_if green 2337/2349 no delta). branchOnReg = the 5-case
  conditional-branch-to-label core (cond-return / loop+param / loop-direct / fwd-block-capture /
  fwd-simple), now shared. (ref.test/cast family R-1/R-2/R-3 all DONE both arches — `c2a8fd11`/
  `8e3f6a83`/`b6cf1ce8` — via the SHARED Runtime-free `gcRefMatchesNonNullCore` + `jitGcRefTest`
  (test→i32) / `jitGcRefCast` (cast→ref/0=trap) trampolines.)
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`); JIT corpus run = §1. JIT emits
  1.0/2.0 + TC + func-refs + EH + i31 + full struct family + full array family + ref.eq +
  **ref.test/test_null/cast/cast_null** (both arches); remaining GC = br_on_cast/br_on_cast_fail
  (D-211). Green gc/EH corpus = INTERP.
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
- **DONE both arches**: i31 + struct.{new_default,get,new,set} + **array.\* (all 12)** + ref.eq
  + **ref.test/test_null (R-1) + ref.cast (R-2) + ref.cast_null (R-3)**. Per-op SHAs in `git log`.
  Per-GC-op touch-points (REUSE): op-file ×2 + `collected_{arm64_ops,x86_64_ctx_ops}` + bump
  dispatch_collector.zig count LITERALS + `stackEffect` + x86_64 `usesRuntimePtr` (R15 CALL ops)
  + regalloc_compute force-spill (CALL ops) + ungated `runI32Export` e2e (**hand-encode:
  wat2wasm 1.0.40 can't parse GC array/ref text; ref.cast leaves a REF on stack — trap-test
  bodies need `drop; i32.const 0` to type-check; i32.const ≥ 64 needs multi-byte signed LEB128**).
- **NEXT = br_on_cast / br_on_cast_fail emit, both arches** (0xFB 0x18/0x19) — cast + BRANCH
  (control-flow; full plan in **`private/notes/p10-br-on-cast-survey.md`**). **Cycle A DONE**
  (`branchOnReg` extracted, `7a44f910`). Cycle B (NEXT): `emitBrOnCast(ctx/params, is_fail)` in
  op_control.zig (both arches) + an emit.zig switch arm each (`.br_on_cast` / `.br_on_cast_fail`
  → emitBrOnCast). Recipe: PEEK ref (don't pop — `ctx.pushed_vregs` top stays), `ht2 =
  (ins.extra>>8)&0xFF`, `ht2_nullable = (ins.extra&0x02)!=0`; marshal ref→arg1 (64-bit) + rt +
  `ht2 | (ht2_nullable?0x100:0)` → CALL jitGcRefTest → bool in W0/EAX; for `_fail` INVERT the
  bool (CMP W0,#0;CSET W0,.eq / TEST EAX,EAX;SETE — reuse existing encoders, no sense param in
  branchOnReg); then `branchOnReg(..., W0)`. The ref stays as pushed_vregs top → branchOnReg's
  merge-mov carries it to the label (br_on_cast label result = the narrowed ref). LIVENESS gap:
  add `.br_on_cast`/`.br_on_cast_fail` beside `.br_if` (liveness.zig:414) as PEEK-don't-pop
  (extend top ref's last_use=pc, no pop). Also: regalloc_compute force-spill + x86_64
  usesRuntimePtr for both (they CALL jitGcRefTest). NOT collected per-op (central-switch) → no
  dispatch_collector count bumps. HAZARD: W0 read before merge MOVs clobber it (branchOnReg's
  block-capture path reads cond first — OK; verify). e2e: block `(result (ref i31))` + ref.i31 +
  `br_on_cast $L (ref null any)(ref i31)` → branch carries i31ref → i31.get_s → 7 (hand-encode;
  block-type (ref i31) = `0x64 0x6c`; br_on_cast = `fb 18 flags labelidx ht1 ht2`).
- **Exit-condition**: all GC ops emit on both arches + spec corpus green via JIT mode (§1).

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

**Cycle A (branchOnReg refactor) kicked to ubuntu THIS turn** (background `test-all`, against the
turn's pushed HEAD = the Cycle-A + handover chain tip). Next `/continue`: `tail -3 /tmp/ubuntu.log`
— expect `[run_remote_ubuntu] OK (HEAD=<Cycle-A chain tip>)`. On FAIL: revert to the last
ubuntu-verified HEAD (`ca2ce49f` = R-3). On GREEN: proceed to br_on_cast **Cycle B** (emitBrOnCast
+ liveness + e2e; recipe in Active-bundle NEXT + `private/notes/p10-br-on-cast-survey.md`). The
refactor being behaviour-neutral, br_if regression on ubuntu would be the signal.

**Maintenance interlude (2026-05-31)**: a context-budget + scaffolding commit landed on top of
`b7672df0` (no src/test change — 200K-pin, hook dedup, rule condense; see CLAUDE.md "Context
budget" + memory `feedback_context_budget_posture`). ubuntu green at `b7672df0` still validates
code; Cycle B resumes unchanged.

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own
them) — parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan); ADR-0116 (RTT 8-deep Cohen display + subtype check);
  ADR-0127 (cross-module func type-identity); ADR-0126 (canonical type ids); ADR-0115 §10
  (non-moving β collector); ADR-0060 (force-spill). ROADMAP §10.
- Debt: **D-211** (GC-on-JIT), D-212 (GC FP-value marshal gap), D-209 (stale), D-202 / D-198 /
  D-210. Lessons `2026-05-31-jit-passthrough-result-clobbered-by-call` +
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` + `...-partial-spec-corpus-interp`.
