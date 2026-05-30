# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). The prior "close-eligible" posture is RETRACTED: §10 exit requires the
  official Wasm 3.0 testsuite at pass=fail=skip=0 on **both backends** (interp + JIT).
- **HEAD**: `e853fda4` (cyc249 — 10.G **cycle A-1**: shared `allocStructObject` helper +
  behavior-neutral interp adoption; first struct-on-JIT code). cyc246 (x86_64 i31)
  ubuntu-verified green; cyc247-248 = design grounding (turn-key spec in plan doc).
- **Two execution paths (CODE-verified)**: the spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`). The JIT emits 1.0/2.0 +
  tail-call + function-references + EH + **i31 (both arches)**; remaining GC (struct/
  array/ref.cast/ref.eq) still interp-only (D-211). Green gc/EH spec corpus is INTERP
  coverage; the JIT is unverified against the corpus.
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
- **Cycles-remaining**: ~5-6
- **Continuity-memo**: the PROVEN per-GC-op recipe (5 touch-points, validated by i31 both
  arches) + the full struct.new design live in **`.dev/phase10_g_op_bundle_plan.md`
  §"GC-on-JIT emit design"** (single source — do NOT re-derive). Key invariants: arm64→
  `collected_arm64_ops`, x86_64→`collected_x86_64_ctx_ops`; `stackEffect` entry per value
  op; trap-emitting ops → x86_64 `usage.zig` `usesRuntimePtr` (D-180); `Value.anyref`=u32
  on stack; struct offsets UNIFORM `8+idx*8` (ADR-0116 §3a); GC types are runtime-only
  (`inst.gc_type_infos`) → struct.new needs `field_count` threaded to compile-time; rooting
  DEFERRED (non-moving). e2e = `runI32Export` (hand-encode wasm; wat2wasm 1.0.40 lacks GC text).
- **First-op order**: (1) **i31** — DONE both arches (`97658b5d`). struct ops decomposed
  TURN-KEY in **`.dev/phase10_g_op_bundle_plan.md` §"Cycle decomposition (cyc248)"**.
  **A-1 DONE** (`e853fda4`): shared `feature/gc/object_alloc.zig` `allocStructObject(heap,
  typeidx,payload_size,zero_init)→GcRef` + behavior-neutral interp adoption. **NEXT = Cycle
  A-2** (full spec in plan doc §"Cycle decomposition"): JitRuntime += `gc_heap`/
  `gc_type_infos_ptr` fields (memory_grow_fn pattern) + `shared/gc_alloc_trampoline.zig`
  `jitGcAlloc(rt,typeidx) callconv(.c)` wrapping `allocStructObject` + `setupRuntime`
  (setup.zig:501) GC-heap/gc_type_infos wiring + arm64 `struct_new_default`/`struct_get` emit
  + stackEffect (0→1 / 1→1) + usesRuntimePtr + runI32Export `struct.new_default 0; struct.get
  0 0`→0 (then x86_64). A-3 = struct.new (variadic + ADR-0060 force-spill). (3) array.*
  (4) ref.cast (5) ref.eq.
- **Exit-condition**: i31 green via `runI32Export` both arches — **DONE** (`97658b5d`).
  Bundle continues to struct/array/ref.cast; close when all GC ops emit + corpus green.

## §10 remaining — the six `[ ]` rows (精査)

- **10.M** memory64 — corpus green; **D-209 is STALE** (payload u64; spec max offset =
  2^32−1; lift the leftover u32 check → done).
- **10.R** function-references — JIT emit present, corpus green; residual = **D-198**.
- **10.TC** tail-call — JIT matrix complete; residuals = **D-210** + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21; now provisioned, §5).
- **10.G** GC — **JIT emit PARTIAL (D-211)**: i31 family DONE both arches (cyc245-246);
  remaining = struct/array/ref.cast/ref.eq both arches + **ADR-0127 PHASE C** + D-198 +
  gc_stress (I19) + dart/hoot realworld (I21, §5). GC-on-JIT = op-emit (§2).
- **10.P** close — flips to close only at 100% both-backends (ADR-0128); the
  close-eligible SKIP invariants (I16 GC-on-JIT; I3/I5/I19/I20/I21; I11/I14/I23) become
  REAL targets, not permanent SKIPs.

## Step 0.7 (next resume)

cyc246 (`97658b5d`, x86_64 i31 + ungated e2e) ubuntu-verified green `OK (HEAD=bd4729db)` —
the null-trap path (R15 trap stub / `usesRuntimePtr` D-180) passed on real x86_64. cyc249
(`e853fda4`) = A-1 helper + behavior-neutral interp refactor (touches interp struct_ops →
runs on x86_64); ubuntu kick pending → verify `tail -3 /tmp/ubuntu.log` next resume.

## Key refs

- **ADR-0128** (Phase 10 100% both-backends — the master plan); ADR-0127 (Accepted,
  cross-module func type-identity); ADR-0115 §10 (non-moving β collector; reclamation →
  Phase 11); ADR-0066 / ADR-0112+Amendment (cross-module TC).
- Debt: **D-211** (GC-on-JIT), D-209 (memory64 offset — stale), D-202 / D-198 / D-210.
- Lessons `2026-05-31-wasmgc-jit-non-moving-deferred-rooting`,
  `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp`. ROADMAP §10.
