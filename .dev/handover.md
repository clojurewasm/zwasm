# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: 10.G **array A-6a+A-6b** (`array.get_s` + `array.get_u` emit both arches). = `array.get`
  (A-3: null-trap + bounds-check + 8-byte slot load at `[base+12+idx*8]`) + a final packed-extend
  to i32: get_s sign-extends (arm64 SXTB/SXTH; x86_64 MOVSX), get_u zero-extends (arm64 UXTB/UXTH
  `encUxtbW`/`encUxthW`; x86_64 `encMovzxR32R16`). Packed width (i8 0x78 / i16 0x77) threaded
  type-section→`ZirInstr.extra` via new `array_elem_valtypes` table (mirror `struct_field_counts`:
  compile.zig→compileOne→lowerFunctionBodyWith→Lowerer; lower stamps sub∈{12,13}). emit switch on
  extra (else unreachable; validator restricts to packed). e2e: i8 elem 0xC8 → get_s -56 (u32
  4294967240) / get_u 200. A-6a `25218e9f` (ubuntu GREEN `261350de`); A-6b THIS turn. (A-5
  `d4f2a141` + A-1..A-4 DONE.) Verified: arm64 `test-all` EXIT=0 + lint 0 + x86_64 cross EXIT=0.
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`); JIT corpus run = §1. JIT emits
  1.0/2.0 + TC + func-refs + EH + i31 + full struct family + array.{new_default,len,get,set,
  new,new_fixed,get_s,get_u} (both arches); remaining GC (array bulk fill/copy/init + ref.cast /
  ref.eq) interp-only (D-211). Green gc/EH corpus = INTERP.
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
  (`array.get_u` = same + UXTB/UXTH / MOVZX; encUxtbW/encUxthW/encMovzxR32R16 added) THIS turn
  DONE both arches.
  **NEXT = array A-7 = `array.fill` emit, both arches** (trampoline, mirror array.new A-4) — full
  recipe in bundle plan §"array.* sub-bundle": NEW `jitGcArrayFill(rt,typeidx,ref,idx,value,count)
  → u32` (1=ok/0=trap; null+bounds-check+fill in Zig), emit marshals 6 args → CALL → `CMP 0; B.EQ
  → bounds_fixups`; 4→0; inclusive force-spill. Then array.copy / new_data/new_elem, ref.cast/eq.
- **Exit-condition**: all GC ops emit on both arches + spec corpus green via JIT mode (§1).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit PARTIAL (D-211): i31 + **full struct family** + **array.{new_default,
  len,get,set,new,new_fixed,get_s,get_u}** DONE both arches; remaining = array bulk fill/copy/init
  (A-7+) + ref.cast / ref.eq + ADR-0127 PHASE C + D-198 + gc_stress (I19) + dart/hoot realworld (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

This turn landed array A-6b code (`array.get_u`) + this handover chore; prior cycle's A-6a
`25218e9f` already ubuntu-verified GREEN (`OK (HEAD=261350de)`). ubuntu **test-all** kicked in
background against this turn's pushed HEAD (`/tmp/ubuntu.log`). Step 0.7 next `/continue`:
`tail -3 /tmp/ubuntu.log`; expect `OK (HEAD=<final pushed SHA>)`. On FAIL → `git reset --mixed
HEAD~2` (A-6b source + this handover chore) to last ubuntu-verified HEAD (`261350de`), fix,
re-gate. On GREEN/non-code-gap → proceed to array A-7 (`array.fill`).

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own them) — parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan); ADR-0127 (cross-module func type-identity);
  ADR-0115 §10 (non-moving β collector); ADR-0060 (force-spill + A-3 amend). ROADMAP §10.
- Debt: **D-211** (GC-on-JIT), D-209 (stale), D-202 / D-198 / D-210. Lessons
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` + `...-partial-spec-corpus-interp`.
