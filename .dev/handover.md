# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: 10.G **A-9 `array.copy`** emit both arches. Bulk op, trampoline (mirror array.fill
  A-7): NEW `jitGcArrayCopy(rt, dst_ref, dst_off, src_ref, src_off, len) → u32` (1=ok/0=trap)
  null-checks both refs + bounds-checks both ranges (@addWithOverflow) + overlap-aware copy
  (backward when same array + dst_off>src_off) in Zig (mirror interp arrayCopy). Element slot =
  uniform 8 bytes (ADR-0116 §3a) → the two typeidx immediates are DROPPED, keeping the call at
  exactly **6 args** (no 7th-on-stack, no offset-packing); trampoline needs only `rt.gc_heap`.
  Emit = 6-arg marshal (arg regs ∉ regalloc pool, no parallel-move hazard) + CALL + `CMP/TEST 0;
  B.EQ/JE → bounds_fixups`. 5→0; strict force-spill; usesRuntimePtr. e2e: copy src[0,1]→dst[1,2],
  array.get dst[2] → 20. (A-1..A-8 DONE; A-8 `ref.eq` ubuntu GREEN `31f1f2da`.) A-9 THIS turn.
  Verified: arm64 `test-all` EXIT=0 + lint 0 + x86_64 cross EXIT=0.
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`); JIT corpus run = §1. JIT emits
  1.0/2.0 + TC + func-refs + EH + i31 + full struct family + array.{new_default,len,get,set,
  new,new_fixed,get_s,get_u,fill,copy} + ref.eq (both arches); remaining GC (array new_data/
  new_elem + ref.cast/test) interp-only (D-211). Green gc/EH corpus = INTERP.
- **ADR-0128 + ADR-0127 both Accepted** — no remaining user gate; loop runs autonomously.

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
- **Cycles-remaining**: ~4-5
- **Continuity-memo**: PROVEN per-GC-op recipe + full struct design in
  **`.dev/phase10_g_op_bundle_plan.md`** §"GC-on-JIT emit design" (single source — do NOT
  re-derive) + §"array.* sub-bundle". Verified x86_64 facts: pinned rt = R15; SysV args
  RDI/RSI(/EDX), ret EAX; emit scratch = `spill_stage_gprs` {R10=stage0, R11=stage1} — NOT in
  regalloc pool (`allocatable_gprs` {RBX,R12,R13,R14}; don't use R13/R14 ad-hoc); result via
  gprDefSpilled/gprStoreSpilled (encoders: read existing x86_64 struct files). x86_64 ctx-op
  count test in dispatch_collector.zig is a LITERAL — bump per added op. struct offsets UNIFORM
  `8+idx*8` (ADR-0116 §3a); array offsets `12+i*8` (4-mod-8, register-offset); rooting DEFERRED.
- **First-op order**: i31 + **struct.{new_default,get,new,set}** all DONE both arches. Per-GC-op
  touch-points (REUSE for array; full list in bundle plan §"array.* sub-bundle"): op-file +
  register in `collected_{arm64_ops,x86_64_ctx_ops}` + bump dispatch_collector.zig count LITERALS
  + `stackEffect` (or liveness special-case if variadic) + x86_64 `usesRuntimePtr` (R15 ops) +
  ungated `runI32Export` e2e (**hand-encode: i32.const ≥ 64 needs multi-byte signed LEB128** —
  bit 6 sign-extends; keep test values < 64) + ADR-0060 force-spill for alloc ops (is_call).
  array A-1 (trampoline) `06ebc165` + A-2 (new_default + len) `d6dea34d` + A-3 (get + set,
  register-offset + bounds-check) `dc5869ca` + A-4 (array.new via `jitGcAllocArrayFill`
  trampoline-fill) `690bcf0d` + A-5 (`array.new_fixed`, variadic, `jitGcAllocArray(rt,typeidx,N)`
  + inline reverse-pop stores, inclusive force-spill) `d4f2a141` + A-6a (`array.get_s` = A-3 load
  + SXTB/SXTH; element valtype threaded via `array_elem_valtypes`→`extra`) `25218e9f` + A-6b
  (`array.get_u` = same + UXTB/UXTH / MOVZX) `62de416c` + A-7 (`array.fill` = `jitGcArrayFill`
  trampoline, 6-arg marshal + post-CALL trap) `17088594` + A-8 (`ref.eq` = CMP+CSET/SETE, no
  trampoline) `a0eae42a` + A-9 (`array.copy` = `jitGcArrayCopy` trampoline, 6-arg marshal,
  typeidx dropped/esz=8) THIS turn DONE both arches.
  **NEXT = A-10 = `array.new_data` + `array.new_elem` emit, both arches** — alloc-from-segment
  trampolines (mirror array.new A-4): pop offset + size (i32), alloc a length-`size` array then
  copy `size` elements from data/elem segment `$segidx` at byte/elem `offset`. Survey needed:
  how the trampoline reaches the instance's data/elem segments (rt.gc_heap is there; need the
  segment bytes — likely a new JitRuntime field or via the instance pointer). Then ref.test /
  ref.cast (RTT type-hierarchy sub-bundle — Cohen 8-deep display per ADR-0116; architectural).
- **Exit-condition**: all GC ops emit on both arches + spec corpus green via JIT mode (§1).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit PARTIAL (D-211): i31 + **full struct family** + **array.{new_default,
  len,get,set,new,new_fixed,get_s,get_u,fill,copy}** + **ref.eq** DONE both arches; remaining =
  array new_data/new_elem (A-10) + ref.cast/test (RTT) + ADR-0127 PHASE C + D-198 + gc_stress
  (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

This turn landed A-9 code (`array.copy`) + this handover chore; prior cycle's A-8 `a0eae42a`
already ubuntu-verified GREEN (`OK (HEAD=31f1f2da)`). ubuntu **test-all** kicked in background
against this turn's pushed HEAD (`/tmp/ubuntu.log`). Step 0.7 next `/continue`: `tail -3
/tmp/ubuntu.log`; expect `OK (HEAD=<final pushed SHA>)`. On FAIL → `git reset --mixed HEAD~2`
(A-9 source + this handover chore) to last ubuntu-verified HEAD (`31f1f2da`), fix, re-gate.
On GREEN/non-code-gap →
proceed to A-10 (`array.new_data`/`array.new_elem`).

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own them) — parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan); ADR-0127 (cross-module func type-identity);
  ADR-0115 §10 (non-moving β collector); ADR-0060 (force-spill + A-3 amend). ROADMAP §10.
- Debt: **D-211** (GC-on-JIT), D-209 (stale), D-202 / D-198 / D-210. Lessons
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` + `...-partial-spec-corpus-interp`.
