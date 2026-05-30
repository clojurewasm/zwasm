# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). The prior "close-eligible" posture is RETRACTED: §10 exit requires the
  official Wasm 3.0 testsuite at pass=fail=skip=0 on **both backends** (interp + JIT).
- **HEAD**: `c2a8d776` (cyc244 — 100% plan + GC-on-jit bundle opened). cyc232-242 landed +
  ubuntu-verified (cross-module return_call, EH×TC, D-202 PHASE A/B-finality).
- **Two execution paths (CODE-verified)**: the spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`). The JIT emits 1.0/2.0 +
  tail-call + function-references + EH; it does **NOT** emit **GC** (D-211). So the
  green gc/EH spec corpus is INTERP coverage; the JIT is unverified against the corpus.
- **ADR-0128 + ADR-0127 both Accepted (2026-05-31, user "100%")** — no remaining user
  gate; the loop executes the workstreams below autonomously.

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128). Drive in this order; each is value-prioritized, NOT the
§10 table-first `[ ]` (the six `[ ]` rows are parallel proposal tracks):

1. **Spec-corpus JIT execution mode** (§1) — the verification backbone: run the official
   testsuite through the JIT (compile-every-fn → JIT-entry invoke → compare; wasmtime
   `tests/wast.rs` pattern). Makes every JIT gap (incl. GC) show up RED. Host-call
   thunking + typed trap mapping + multi-value + NaN patterns; `assert_invalid` stays on
   the validator path. Per-backend `should_fail` list, flipped as features land.
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
- **Cycles-remaining**: ~6-8
- **Continuity-memo**: (Step-0 survey captured 2026-05-31; do NOT re-survey)
  Op-file pattern = `codegen/{arm64,x86_64}/ops/wasm_3_0/<op>.zig` exposing `pub const
  op_tag: ZirOp` + `wasm_level: .v3_0` + `pub fn emit(ctx: *EmitCtx, ins: *const
  ZirInstr) Error!void`; register in BOTH `collected_{arm64,x86_64}_ops` tuples in
  `dispatch_collector_ops.zig` (`dispatch_collector.dispatch` matches op_tag → emit, else
  legacy switch in `emit.zig`). JIT→runtime helper convention (model =
  `shared/throw_trampoline.zig`): rt ptr pinned X19/R15; args X0-X3 / RDI-RCX; BLR X16 /
  CALL R10; result X0/RAX. Heap (`feature/gc/heap.zig`): `allocate(size)→GcRef`=u32 slab
  offset; ObjectHeader 8B (kind u8 + pad + info=typeidx u32); `StructInfo.fields[i].offset`
  (8B-uniform). `Value.anyref`=u32 on stack (regalloc treats like i32). Harness =
  `runI32Export(alloc, wasm_bytes, name)` (no-arg→i32) in `engine/runner.zig`. Per-op
  lowering recipe: ADR-0128 §2. Rooting DEFERRED (non-moving; `is_safepoint=false` for now).
- **First-op order**: (1) **i31** (`ref.i31`/`i31.get_s`/`_u`) — non-allocating shift+tag,
  NO trampoline/type-info; establishes the GC op-file+registration pattern (MATCH the
  interp i31 encoding — `src/instruction/wasm_3_0/{ref_i31,i31_get_s,i31_get_u,i31_ops}.zig`).
  (2) struct.new/get
  (add `shared/gc_alloc_trampoline.zig`). (3) array.*. (4) ref.cast/test (Cohen display,
  `n1>=n2` guard). (5) ref.eq. Then workstream 1 (spec-corpus JIT mode) verifies at scale.
- **Exit-condition**: i31 (`ref.i31`+`i31.get_s`) green via `runI32Export`, Mac arm64 then
  x86_64; `Builder`/emit byte-test present. Bundle continues to struct/array/ref.cast.

## §10 remaining — the six `[ ]` rows (精査)

- **10.M** memory64 — corpus green; **D-209 is STALE** (payload u64; spec max offset =
  2^32−1; lift the leftover u32 check → done).
- **10.R** function-references — JIT emit present, corpus green; residual = **D-198**.
- **10.TC** tail-call — JIT matrix complete; residuals = **D-210** + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21; now provisioned, §5).
- **10.G** GC — **JIT emit ABSENT (D-211)** + **ADR-0127 PHASE C** + D-198 + gc_stress
  (I19) + dart/hoot realworld (I21, §5). GC-on-JIT difficulty corrected (op-emit, §2).
- **10.P** close — flips to close only at 100% both-backends (ADR-0128); the
  close-eligible SKIP invariants (I16 GC-on-JIT; I3/I5/I19/I20/I21; I11/I14/I23) become
  REAL targets, not permanent SKIPs.

## Step 0.7 (next resume)

cyc239 PHASE B-finality (`a4bd9bbb`) ubuntu-verified `OK (HEAD=64b27118)`. cyc240-244 are
docs/research-only → no ubuntu pending, no revert.

## Key refs

- **ADR-0128** (Phase 10 100% both-backends — the master plan); ADR-0127 (Accepted,
  cross-module func type-identity); ADR-0115 §10 (non-moving β collector; reclamation →
  Phase 11); ADR-0066 / ADR-0112+Amendment (cross-module TC).
- Debt: **D-211** (GC-on-JIT), D-209 (memory64 offset — stale), D-202 / D-198 / D-210.
- Lessons `2026-05-31-wasmgc-jit-non-moving-deferred-rooting`,
  `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp` (+ cohort-asymmetry,
  stale-debt, clang-recipe). ROADMAP §10; `toolchain_provisioning.md`.
