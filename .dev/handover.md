# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). The prior "close-eligible" posture is RETRACTED: §10 exit requires the
  official Wasm 3.0 testsuite at pass=fail=skip=0 on **both backends** (interp + JIT).
- **HEAD**: `3e05fa62` (cyc245 — first GC-on-JIT op family: **arm64 i31 emit**
  ref.i31/i31.get_s/i31.get_u, `runI32Export`-green). cyc232-242 ubuntu-verified.
- **Two execution paths (CODE-verified)**: the spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`). The JIT emits 1.0/2.0 +
  tail-call + function-references + EH + (now) **arm64 i31**; remaining GC (struct/
  array/ref.cast/ref.eq + **x86_64 i31**) still interp-only (D-211). Green gc/EH spec
  corpus is INTERP coverage; the JIT is unverified against the corpus.
- **ADR-0128 + ADR-0127 both Accepted (2026-05-31, user "100%")** — no remaining user
  gate; the loop executes the workstreams below autonomously.

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128). Drive in this order; each is value-prioritized, NOT the
§10 table-first `[ ]` (the six `[ ]` rows are parallel proposal tracks):

1. **Spec-corpus JIT execution mode** (§1) — verification backbone: run the official
   testsuite through the JIT (compile-every-fn → JIT-entry invoke → compare; wasmtime
   `tests/wast.rs` pattern) so every JIT gap (incl. GC) shows up RED. Host-call thunking +
   typed trap mapping + multi-value + NaN; `assert_invalid` stays on validator path.
2. **GC-on-JIT op emit** (D-211 bundle; §2) — struct/array/ref.cast/i31/ref.eq, both
   arches. NON-moving collector + β no-reclaim ⇒ **rooting deferred** (no safepoints /
   stack-maps); this is op-emit like the landed EH/TC op files, NOT regalloc surgery.
   ref.cast = Cohen supertype-vector display (`n1>=n2` guard, CVE-2024-4761).
3. **ADR-0127 PHASE C** — cross-`Types` `canonicalEqual`; `gc/type-subtyping`
   assert_unlinkable 5→0.
4. Quick wins: **D-209** (lift the leftover `>u32` offset check, `lower.zig:864-867` +
   `lower_simd.zig:372`; payload is already u64), then **D-198** (rec-group subtype),
   **D-210** (cross-module proper-tail-call — arm64 prologue cohort-save).
5. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` (triple
   crown) / `emcc -fwasm-exceptions` / `guile-hoot`; `wat2wasm --enable-all` lever for
   per-opcode gaps. Updates `toolchain_provisioning.md`.

## Active bundle

- **Bundle-ID**: `10.G-gc-on-jit-IT-1..N`
- **Cycles-remaining**: ~6-7
- **Continuity-memo**: (survey captured 2026-05-31; do NOT re-survey) Op-file pattern =
  `codegen/{arm64,x86_64}/ops/wasm_3_0/<op>.zig` (`pub const op_tag/wasm_level/wasi_level`
  + `pub fn emit(ctx,ins) Error!void`), register in `collected_{arm64,x86_64}_ops` in
  `dispatch_collector_ops.zig`. **THREE more touch-points the survey missed, learned
  cyc245**: (a) add a `stackEffect` 1→1 entry per GC *value* op in
  `ir/analysis/liveness_stack_effect.zig` (drives BOTH liveness + `populateShapeTags`;
  non-SIMD producers auto-tag `.scalar`=GPR, correct for anyref-u32) — without it,
  liveness errors `UnsupportedOp[stackEffect-missing]`; (b) bump the per-arch count in
  `dispatch_collector.zig` `migratedArchOpCount` test; (c) `runI32Export` e2e (no-arg→i32,
  `engine/runner.zig`) is the behavior signal — wat2wasm 1.0.40 has NO i31 text syntax so
  hand-encode bytes (opcodes: ref.i31=`fb 1c`, get_s=`fb 1d`, get_u=`fb 1e`, ref.null
  i31=`d0 6c`; verified vs `test/spec/.../gc/i31/i31.0.wasm`). `Value.anyref`=u32 on
  stack. struct/array (later): trampoline model `shared/throw_trampoline.zig` + heap
  `feature/gc/heap.zig`; rooting DEFERRED (non-moving). Per-op lowering: ADR-0128 §2.
- **First-op order**: (1) **i31** — arm64 DONE (`3e05fa62`: ADD+ORR tag / TST+B.EQ-trap +
  ASR|LSR; encoders `encAsrImmW/encOrrImm1W/encTstImm1W`). **NEXT = x86_64 i31** (mirror):
  add `encSarRImm8` + `encOrRImm8` to x86_64 `inst_alu` (SHR already exists; TEST r,#1 via
  `encTestRImm32`; JE via `encJccRel32`→bounds_fixups), 3 op-files, register in
  `collected_x86_64_ops`, then UNGATE the 3 `runI32Export` i31 tests (drop the
  `if (arch != aarch64) skip.blocker(.@"D-211")`) + remove the `@"D-211"` Blocker variant.
  (2) struct.new/get (add `shared/gc_alloc_trampoline.zig`). (3) array.*. (4) ref.cast/test
  (Cohen display, `n1>=n2` guard). (5) ref.eq. Then workstream 1 (spec-corpus JIT mode).
- **Exit-condition**: i31 (`ref.i31`+`i31.get_s`) green via `runI32Export` — Mac arm64
  DONE; x86_64 pending (next cycle). Bundle continues to struct/array/ref.cast.

## §10 remaining — the six `[ ]` rows (精査)

- **10.M** memory64 — corpus green; **D-209 is STALE** (payload u64; spec max offset =
  2^32−1; lift the leftover u32 check → done).
- **10.R** function-references — JIT emit present, corpus green; residual = **D-198**.
- **10.TC** tail-call — JIT matrix complete; residuals = **D-210** + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21; now provisioned, §5).
- **10.G** GC — **JIT emit PARTIAL (D-211)**: arm64 i31 landed cyc245; remaining =
  x86_64 i31 + struct/array/ref.cast/ref.eq both arches + **ADR-0127 PHASE C** + D-198 +
  gc_stress (I19) + dart/hoot realworld (I21, §5). GC-on-JIT = op-emit (§2).
- **10.P** close — flips to close only at 100% both-backends (ADR-0128); the
  close-eligible SKIP invariants (I16 GC-on-JIT; I3/I5/I19/I20/I21; I11/I14/I23) become
  REAL targets, not permanent SKIPs.

## Step 0.7 (next resume)

cyc245 (`3e05fa62`) = arm64 i31 emit. The 3 `runI32Export` i31 tests are aarch64-gated
(`skip.blocker(.@"D-211")`) → they SKIP on ubuntu x86_64; encoder/stackEffect/registration
changes are arch-independent. So the cyc245 ubuntu kick should be green; verify
`tail -3 /tmp/ubuntu.log` next resume. cyc240-244 docs/research-only → no revert.

## Key refs

- **ADR-0128** (Phase 10 100% both-backends — the master plan); ADR-0127 (Accepted,
  cross-module func type-identity); ADR-0115 §10 (non-moving β collector; reclamation →
  Phase 11); ADR-0066 / ADR-0112+Amendment (cross-module TC).
- Debt: **D-211** (GC-on-JIT), D-209 (memory64 offset — stale), D-202 / D-198 / D-210.
- Lessons `2026-05-31-wasmgc-jit-non-moving-deferred-rooting`,
  `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp`. ROADMAP §10.
