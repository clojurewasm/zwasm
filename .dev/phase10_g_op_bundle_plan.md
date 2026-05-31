# Phase 10 / 10.G op_gc bundle plan

> **Doc-state**: ACTIVE — load-bearing for the 10.G op_gc impl
> bundle (post-foundation; ROADMAP §10 row 10.G). Drafted via
> /continue autonomous prep path 2026-05-27 after the 6-cycle
> 10.G-foundation bundle closed (HEAD `62bebe25`). Captures the
> integration path so the next bundle starts with a sequenced
> sub-chunk list rather than re-deriving from ADR-0115/0116.

## Foundation already landed (10.G-foundation bundle, 6 cycles)

| Component | Path | Purpose | Cycle |
|---|---|---|---|
| Value.anyref arm | `src/runtime/value.zig` | 32-bit GcRef slot in Value union (parallel to ref:u64) | 1 (`e953b089`) |
| Module.needs_gc_heap flag | `src/runtime/module.zig` | Parse-time predicate field | 1 (`e953b089`) |
| needs_heap_detector wiring | `src/parse/parser.zig` | parser.parse populates the flag | 2 (`3fa32ddf`) |
| Heap (per-Store slab) | `src/feature/gc/heap.zig` | Bump-pointer alloc; 4 KB grow; 4 GiB cap; 2-byte align | 3 (`e3bd30e1`) |
| Collector vtable | `src/feature/gc/collector_iface.zig` | allocObjectFn + collectFn + walkRootsFn | 4 (`e5eed624`) |
| collector_null α | `src/feature/gc/collector_null.zig` | Wraps Heap as alloc-only | 4 (`e5eed624`) |
| Runtime.gc_heap field + deinit | `src/runtime/runtime.zig` | Optional `?*Heap` slot + cleanup | 5 (`96a17d5a`) |
| instantiate-side gate | `src/runtime/instance/instantiate.zig` | Materialise Heap iff needs_gc_heap | 5 (`96a17d5a`) |
| -Dgc build option | `build.zig` + `feature/gc/register.zig::enable_gc` | Compile-time strip seam | 6 (`62bebe25`) |

Tests: 18 new tests across foundation cycles. zig build test 2117/2131
at foundation close.

## What this bundle needs to land (sequenced)

### Sub-chunk 1 — GC valtype enum extension (ADR-grade decision)

**Status**: NOT YET STARTED; design choice required first.

ADR-0115 §6 specifies the `anyref` Value arm; this bundle's
analogue at the ValType level (`ir/zir.zig::ValType` enum) is
NOT yet authorised by an Accepted ADR. ADR-0116 §"Internal
hierarchy" lists `anyref / eqref / structref / arrayref /
i31ref` but doesn't pick the enum-extension shape.

Two shapes are viable:

(a) **Extend the closed enum** with 5 new variants. Cascade:
~217 exhaustive switch sites add 5 arms each. Mitigation: per
`platform_panic_vs_error.md`, use `@panic("GC valtype:
unsupported")` in cycle-1 dispatch arms so the Error set
stays narrow. Cycle-1 enables parse-time recognition; semantic
op handlers light up the @panic sites as they land.

(b) **Reshape ValType as non-exhaustive** (`enum(u8) { …, _ }`).
217-site cascade avoided; existing switches keep working. But
non-exhaustive enums lose Zig's exhaustiveness checking — every
switch needs `else =>` arm, which the `require_exhaustive_enum_
switch` lint rejects unless the enum is declared non-exhaustive.
Per ADR-0009 the lint discipline is load-bearing.

**Recommendation**: (a) closed-enum with @panic cascade.
Preserves exhaustiveness guarantees; cycle-1 effort is mechanical
(rg-find + sed-shape). The @panic arms die naturally as op_gc
handlers land per sub-chunk.

ADR amendment needed: extend ADR-0115 §6 (currently `anyref:
u32` in Value only) to authorise the ValType enum extension +
cite the @panic cascade pattern. Single Revision history row.

### Sub-chunk 2 — Parser: GC valtype byte decode

`src/parse/sections.zig::readValType` (and call sites) recognise
the 5 GC bytes:
- anyref 0x6E → `.anyref`
- eqref 0x6D → `.eqref`
- structref 0x6B → `.structref`
- arrayref 0x6A → `.arrayref`
- i31ref 0x6C → `.i31ref`

Type-section + global-section + table-section + element-section
+ code-locals decode paths all consume readValType — single
helper change unblocks all.

### Sub-chunk 3 — Validator: GC valtype semantic stack

Validator stack types accept the 5 new ValTypes. For cycle-3
minimal: stack-push/stack-pop tracking only (no op handlers
that consume them yet). Cycle 4+ wires op_gc handlers.

### Sub-chunk 4 — i31 ops (smallest GC op family; 0xFB 0x1C-0x1E)

`src/instruction/wasm_3_0/i31_ops.zig` already exists as a
stub. i31_pack helpers in `src/feature/gc/i31.zig` provide the
truncate/sign-extend/zero-extend primitives. Wire the 3 i31 ops:
- `ref.i31` (0xFB 0x1C) — pop i32, push i31ref tagged via
  i31_pack.i32ToI31Truncate
- `i31.get_s` (0xFB 0x1D) — pop i31ref, push sign-extended i32
- `i31.get_u` (0xFB 0x1E) — pop i31ref, push zero-extended i32

No heap allocation — i31 lives in low-bit tagged Value (anyref
arm shares encoding per ADR-0116 §135-149). Smallest concrete
GC op family; landing it ungates spec runner for GC i31 fixtures.

### Sub-chunk 5 — struct ops (struct.new / struct.get / struct.set; 0xFB 0x00-0x05)

Heap-allocating ops. Needs TypeInfo / RTT (per ADR-0116) which
itself is a sub-bundle. Defer until i31 + parser substrate land.

### Sub-chunk 6 — array ops (array.new / array.get / array.set; 0xFB 0x06-0x12)

Same shape as struct ops; share heap-alloc + RTT machinery.

### Sub-chunk 7 — ref.test / ref.cast / br_on_cast (0xFB 0x14-0x1B)

Type-testing + cast ops. Need type_hierarchy.zig (RTT 8-deep
display per ADR-0116) which is a separate sub-bundle.

### Sub-chunk 8 — collector_mark_sweep.zig (β must-ship per ADR-0115 §10)

STW mark-sweep over slab; barrier-zero. Implements the vtable
defined at cycle 4. Lands after enough op_gc handlers exist to
exercise heap pressure.

### Sub-chunk 9 — root walker (ADR-0115 §4 Mode A default)

`zwasm_runtime_with_root_scope(rt, callback)` — frozen-collector
host-marks. Required for mark_sweep to find live roots in operand
stack / frame locals / globals.

### Sub-chunk 10 — `-Dgc-collector={null,mark_sweep}` dispatch

Build-option selects which Collector impl `instantiateRuntime`
constructs. Pairs with the `-Dgc` strip seam (cycle 6 of
foundation).

### Sub-chunk 11 — spec corpus (10.G corpus bake; needs D-179 wabt 1.0.41+)

`scripts/regen_spec_3_0_assert.sh` SMOKE set adds `gc/struct` +
`gc/array` + `gc/i31` + `gc/ref-test` once wabt supports the
newer GC type syntax (D-179 barrier).

### Sub-chunk 12 — realworld bake (Dart / wasm_of_ocaml / Hoot)

Per ROADMAP §10 row 10.G exit criteria. Depends on (8) + (9) +
(11).

## Cycle-budget estimate

| Sub-chunk | Cycles |
|---|---|
| 1. ValType enum + ADR amend + cascade | 1-2 |
| 2. Parser valtype recognition | 1 |
| 3. Validator stack types | 1 |
| 4. i31 ops + first spec corpus directive | 2 |
| 5. struct ops + RTT TypeInfo | 4-6 |
| 6. array ops | 2 |
| 7. ref.test / ref.cast / br_on_cast | 2-3 |
| 8. collector_mark_sweep | 3-4 |
| 9. root walker | 2 |
| 10. -Dgc-collector dispatch | 1 |
| 11. spec corpus (D-179 gate) | external |
| 12. realworld (D-179 gate) | external |

Total: ~20 cycles internal + 2 external gates. Multi-session bundle.

## Open dependencies

- **D-179** — wabt 1.0.41+ for spec corpus bake (sub-chunks 11/12).
- **ADR-0115 amendment** — sub-chunk 1's ValType extension
  authorisation. Single Revision row; autonomous-eligible.
- **ADR-0116 verification** — sub-chunk 7's RTT 8-deep display
  needs review of the per-Instance side-table integration.

## Why this plan exists

The 10.G-foundation bundle's 6 cycles landed cleanly (zero
regressions, 18 tests, zero spec-runner delta — pure substrate).
The next bundle is structurally larger and benefits from
sequenced sub-chunks rather than re-deriving the path per
cycle. This doc is the anchor.

## GC-on-JIT emit design (ADR-0128 §2 workstream; cyc245+)

The 12 sub-chunks above are the INTERP 10.G bundle (landed). ADR-0128
(2026-05-31) added the GC-on-JIT **emit** workstream: the JIT must emit
every GC op so the spec corpus passes on BOTH backends. Per-op design:

**i31 — DONE both arches** (cyc245 `3e05fa62` arm64; cyc246 `97658b5d`
x86_64). Non-allocating shift+tag: `ref.i31`=(x<<1)|1; `i31.get_s`=
ASR/SAR #1; `i31.get_u`=LSR/SHR #1; null/non-i31 → bit-0 test + trap
stub. New encoders arm64 encAsrImmW/encOrrImm1W/encTstImm1W; x86_64
encSarRImm8/encOrRImm8. Proven per-op touch-points (REUSE for all GC
ops): (1) op-file `codegen/{arm64,x86_64}/ops/wasm_3_0/<op>.zig`; arm64→
`collected_arm64_ops`, x86_64→`collected_x86_64_ctx_ops`. (2) `stackEffect`
entry (value ops) in `liveness_stack_effect.zig`. (3) bump count tests in
`dispatch_collector.zig`. (4) trap-emitting ops → x86_64 `usage.zig`
`usesRuntimePtr` (else D-180 silent miscompile). (5) `runI32Export` e2e
(hand-encode wasm — wat2wasm 1.0.40 lacks GC text).

**struct.new / struct.get / struct.set — NEXT (multi-cycle architectural;
design grounded cyc247, NO code yet).** Interp contract =
`instruction/wasm_3_0/struct_ops.zig` (allocateStruct:98 / structNew:112 /
structGet:145 / structSet:166).
- **Alloc helper** (ADR-0128 §2 "runtime-call alloc helper, then store
  fields inline"): add JitRuntime `gc_alloc_fn: *const fn(rt,typeidx,
  total_size) callconv(.c) u32` (returns GcRef) + `gc_alloc_fn_off`,
  mirroring `memory_grow_fn` (jit_abi.zig:313 field / :489 off / X-form
  8-aligned ≤32760 comptime budget) + default-reject + wire real fn at
  instance setup. Real fn = `heap.allocate(total_size)` + ObjectHeader
  write (mirror struct_ops.allocateStruct).
- **Offsets UNIFORM** = `8 (header) + field_idx*8` per ADR-0116 §3a →
  get/set need NO type-threading (field_idx is in ZirInstr.extra). Only
  struct.new needs `field_count` (pop count + alloc size
  `(1+field_count)*8`); GC types are runtime-only (`inst.gc_type_infos`,
  instantiate.zig), NOT at emit/compile time today → thread a compile-time
  `[]u32 struct_field_counts` (decode type section structs at compile
  time) into EmitCtx + `liveness.compute`.
- **Liveness**: struct.new variadic-pop special-case (mirror the `call`
  arm, liveness.zig:453 — look up field_count, pop N, push 1). struct.get
  = 1→1, struct.set = 2→0 (fixed `stackEffect` entries).
- **Emit** (model = `emitTableGrow`, op_table.zig:304 = runtime-call-with-
  operand): struct.new = marshal total_size→arg reg, `LDR X16,[X19,
  #gc_alloc_fn_off]; BLR X16` → W0=ref; **reload slab base AFTER the call**
  (alloc may realloc `heap.bytes`); store each field at `[slab+ref+8+i*8]`;
  push ref. struct.get = pop ref, null-trap (CMP #0 + B.EQ→bounds_fixups),
  load `[slab+ref+8+field_idx*8]`.
- **⚠ NEXT-CYCLE BLOCKER SURVEY**: struct.new/array.new must be a
  **regalloc clobber-point** — the alloc BLR clobbers caller-saved, so the
  field vregs (live across the call, stored after) must spill across it.
  `emitTableGrow` does NOT hit this (it consumes its operands INTO the
  call). Survey how `call`/`call_indirect` mark caller-saved clobber in
  `engine/codegen/shared/regalloc*.zig` + add struct.new/array.new.
- usesRuntimePtr += struct.new/get/set (alloc CALL + slab base via R15 +
  trap stub). Packed get_s/get_u (i8/i16 ext) + struct.new_default +
  arrays = follow-on cycles.

**array.* → ref.cast/test → ref.eq** — after struct (share alloc + RTT
machinery; ref.cast = Cohen 8-deep display, `n1>=n2` guard, CVE-2024-4761).

### Cycle decomposition (cyc248 refinement — turn-key)

**New findings cyc248**: (i) `JitRuntime` (jit_abi.zig:139, extern) is SEPARATE
from `Runtime` (runtime.zig:136); `gc_heap`/`instance` live on Runtime, NOT
JitRuntime → the alloc trampoline needs JitRuntime data fields to reach the
heap. (ii) The JIT `setupRuntime` (setup.zig:93) path has NO GC-heap setup
(no Heap, no gc_type_infos) — only the interp `instantiate.zig` materialises
them. (iii) **`struct.new_default` has ZERO field operands** → it sidesteps
the regalloc force-spill + variadic liveness entirely; do it FIRST. (iv)
Trampoline can be a FIXED fn (address materialised at emit, like
`throw_trampoline` — NOT a fn-ptr field) since its logic is fixed (reads rt
fields); it computes payload_size from typeidx via gc_type_infos itself, so
the EMIT needs no field_count threading for new_default. (v) Offsets uniform
`8+idx*8` → get/set need no threading.

- **Cycle A-1** (small, Mac-unit-testable, NO setupRuntime/emit/regalloc):
  JitRuntime += `gc_heap: ?*anyopaque` + `gc_type_infos_ptr: ?*anyopaque`
  (append at struct END to keep existing offsets stable; add `_off` consts +
  comptime budget checks per the memory_grow_fn pattern jit_abi.zig:489/610).
  New `shared/gc_alloc_trampoline.zig`: `pub fn jitGcAlloc(rt: *JitRuntime,
  typeidx: u32) callconv(.c) u32` — cast rt.gc_heap→*Heap, gc_type_infos_ptr→
  *const GcTypeInfos; `si = gti.struct_infos[typeidx].?`; `total = 8 +
  si.payload_size`; `ref = heap.allocate(total) catch return 0`; write
  ObjectHeader{.struct_, .info=typeidx} + zero payload (mirror
  struct_ops.zig allocateStruct:98 + structNewDefault:184); return ref.
  Unit test: build JitRuntime with a Heap + gti (mirror struct_ops
  buildInstanceForTypes:209 — `materialiseGcTypes(a, decodeTypes(body))` for
  `struct{i32}` body `01 5F 01 7F 01`), call jitGcAlloc(&rt,0), assert ref≥2 +
  header.kind=.struct_ + header.info=0 + payload zeroed. **= behavior signal.**
- **Cycle A-2** (emit + setup): extend `setupRuntime` to create Heap +
  materialise gc_type_infos + set the 2 rt fields when a GC type section is
  present (add to RuntimeOwned cleanup). arm64 `struct_new_default.zig` emit
  (MOVZ/MOVK typeidx→W0? no — marshal rt=X0, typeidx=W1; MOV X16,&jitGcAlloc;
  BLR X16; capture W0=ref→result vreg) + `struct_get.zig` emit (pop ref,
  null-trap CMP#0+B.EQ→bounds_fixups, LDR slab=`[X19,#gc_heap_off]`→
  `[heap,#bytes_ptr_off]`, LDR result=`[slab+ref+8+idx*8]`). stackEffect:
  struct.new_default=0→1, struct.get=1→1 (fixed). usesRuntimePtr += both.
  runI32Export round-trip `struct.new_default 0; struct.get 0 0` → 0. x86_64
  mirror. = the real e2e.
- **Cycle A-3**: `struct.new` (variadic) — needs ADR-0060 amendment
  (force-spill alloc-op operands: regalloc_compute.zig:159 strict `<` →
  inclusive for alloc ops, since fields are read AFTER the alloc BLR) +
  variadic liveness (mirror call arm, liveness.zig:453) + field-store-inline.
  `struct.set` (2→0). Then array.* / ref.cast / ref.eq.

## array.* sub-bundle (verified survey, post-struct; cyc-array)

Struct family DONE both arches (`2b942787`). array.* is the next family.
**Verified facts (subagent survey had errors — these corrected via direct
read; do NOT re-trust the uniform-vs-packed / lowering-stub claims):**

- **Layout** (`type_info.zig` ArrayHeader, `@sizeOf == 12`): ObjectHeader
  (8) + `length: u32` @ offset 8. Payload @ offset 12. Element[i] @ `12 +
  i*element.size`; `element.size = slot_size = 8` UNIFORM this cut
  (ADR-0116 §3a). So element offsets are 12,20,28,… = **4-mod-8, NOT
  8-aligned** → `array.get`/`set` (runtime index) MUST use register-offset
  addressing (`LDR Xt,[base, Xidx, LSL#3]` with base = object+12), NOT the
  immediate scaled form struct uses. (arm64/x86_64 allow unaligned normal
  LDR/STR.) `array.len` reads `[base+8]` (offset 8 IS valid).
- **Lowering ALREADY DONE** (`lower.zig` emitPrefixFB): array.new=sub6,
  array.new_default=sub7, array.new_fixed=sub8 (`extra=N`), array.new_data/
  elem=sub9/10 (`extra=segidx`), array.get/get_s/get_u/set/fill=sub11/12/13/
  14/16, array.len=sub15 (`payload=0`). NO lower.zig change needed.
- **Trampoline A-1 DONE** (`06ebc165`): `jitGcAllocArray(rt, typeidx,
  length) callconv(.c) u32` (jit_abi.zig) + `object_alloc.allocArrayObject`
  (zero-inits). length is RUNTIME → arg2 (W2/EDX). Unit-tested.
- **Decomposition (as-built)**: A-2 `d6dea34d` = `array.new_default` (pop
  length→arg2; CALL jitGcAllocArray; strict `is_call`) + `array.len`. A-3
  `dc5869ca` = `array.get` + `array.set` (null-trap, bounds-check `index >=
  [base+8]` UNSIGNED, base+=12, **register-offset** access `[base+idx*8]`;
  x86_64 RAX = 3rd scratch). A-4 `690bcf0d` = `array.new` — **NOT** an
  emitted fill loop (the original plan); instead a new
  `jitGcAllocArrayFill(rt,typeidx,length,init)` trampoline allocs + fills
  inside Zig (mirrors interp arrayNew), so the emit stays marshal+CALL +
  strict `is_call`. **A-5 (NEXT) = `array.new_fixed`** (variadic; N=`extra`
  compile-time): alloc length-N via jitGcAllocArray, reload slab base AFTER
  CALL, store N popped values inline `[base+12+i*8]` (reverse-pop, mirror
  struct.new) → **inclusive force-spill** (is_call=true). Defer get_s/get_u
  (packed; D-212 FP gap) + fill/copy/init_data/init_elem (bulk).
- **Per-op touch-points** (same as struct, see above): op-file + register in
  `collected_{arm64_ops,x86_64_ctx_ops}` + bump dispatch_collector.zig count
  LITERALS + stackEffect (or liveness special-case if variadic) + x86_64
  `usesRuntimePtr` (slab/CALL ops) + ungated runI32Export e2e (test values
  < 64 for single-byte signed LEB128).

## Related

- ADR-0128 §2 (GC-on-JIT emit workstream — the master plan this section
  implements).
- ADR-0115 (GC heap+collector design; cycles 1-6 implement
  §1+§3+§5+§6+§10).
- ADR-0116 (GC roots+RTT+i31 design).
- ADR-0117 (GC×EH×TC integration invariants).
- `.dev/phase10_design_plan_ja.md` §3.5 (industry references +
  β must-ship rationale).
- ROADMAP §10 row 10.G (canonical exit criteria).
