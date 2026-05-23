# 0052 — Adopt per-valtype byte offsets for v128 globals storage

- **Status**: Accepted (per-valtype byte offsets cope-mechanism portion superseded by ADR-0110 Value=16 widen 2026-05-24; the wider ADR-0052 — "Wasm 2.0 v128 globals must be loadable, and ADR-0052 was the Phase 9 §9.9-g-20 emergency landing path" — stays valid as historical record). Once ADR-0110 §9.13-V implementation completes, this ADR's `globals_offsets[]` + `globals_byte_storage` + per-valtype JIT dispatch switch will be removed; only the v128-globals existence + alignment requirement persists in spirit.
- **Date**: 2026-05-11
- **Author**: zwasm-from-scratch loop (chaploud)
- **Tags**: jit, abi, runtime, globals, simd, v128

## Context

§9.9-g-20's parser init_expr fix flipped `simd_const.388.wasm`
from compile-time `UnsupportedConstExpr` to PASS, but exposed
four downstream Mac aarch64 runtime fails of the shape:

```
FAIL  simd_const: global.get_g0(()) → got v128:2e000000... expected v128:01000000010000000100000001000000
```

The root cause sits at the boundary between the runtime's
8-byte `Value` slot (`src/runtime/value.zig:21`,
`@sizeOf(Value)==8` asserted at line 90) and the 16-byte v128
type that Wasm 2.0 SIMD globals demand. ADR-0027 set the
current globals ABI:

- `Runtime.globals_storage: []Value` (8B per global,
  `@sizeOf(Value)`)
- `Runtime.globals: []*Value` (pointer-per-entry for cross-
  module aliasing)
- `JitRuntime.globals_base: [*]Value` (re-used by both
  arches; ARM64 keeps it in X23, x86_64 reloads from R15)
- ARM64 emit: `LDR W<dst>, [X23, #idx*8]` (i32 W-form only)
- x86_64 emit: `MOV R<dst>, [RAX + idx*8]` (i32 only)

ADR-0027 itself listed "Alternative C — pre-computed per-
global byte offsets in a module-level VMOffsets table" as
**deferred** with explicit forward-compat language:

> when imports + SIMD-aligned globals land, this Alternative
> C becomes the natural evolution. The `globals_base +
> globals_count` shape does not preclude it.

This is that moment. The v128-globals decision touches §4
architecture (new ABI field on JitRuntime + new storage
shape on Runtime) and so requires an ADR per ROADMAP §18.2
before code lands.

A textbook survey (Step 0; landed at
`private/notes/p9-v128-globals-survey.md`) found:

| Runtime | Storage shape | Value width | JIT emit |
|---|---|---|---|
| wasmtime/cranelift | uniform 16B inline (`VMGlobalDefinition [u8;16]`) | N/A (raw bytes) | `[vmctx + vmctx_globals_begin() + idx*16]` |
| wasmer (singlepass) | uniform 16B (`RawValue` union 16B) | 16B | `[vmctx + vmglobal_local(idx)]` |
| wazero | dual-field `Val u64 + ValHi u64` per global | (Go: no union, two u64) | per-engine table lookup |
| zwasm v1 | per-global helper call | 8B (no v128 globals) | `BL jitGlobalGet` (~20 cycles) |

Industry consensus (3/4 JIT runtimes): uniform 16-byte
stride, with the surrounding Value-equivalent widened to 16
bytes. zwasm v2 cannot follow that pattern without
widening `Value`, which would ripple through:

- Interp dispatch loop's operand stack slot size
- Host-call marshaling layer (`host_calls`)
- `evalConstExprValue` return type
- Every test asserting `@sizeOf(Value) == 8` (`value.zig:90`)
- ZIR's per-op result valtype assumptions

…all of which currently rely on the §P3 "no per-slot type
byte" / "value is always 8 bytes" invariant.

## Decision

**Adopt Alternative C from ADR-0027: per-valtype byte
offsets via a module-level `globals_offsets` table.** `Value`
stays 8 bytes; v128 globals get a parallel 16-byte storage
path with byte offsets pre-computed at instantiation time
and baked into JIT emit as immediate displacements.

Concretely:

1. **Module-level layout table**. At parse time
   (`parse/sections.zig:decodeGlobals`), compute one
   `globals_offsets: []u32` entry per defined global. Entry
   N = byte offset into the runtime's per-instance globals
   byte buffer where global N lives. Scalar globals (i32 /
   i64 / f32 / f64 / refs) occupy 8 bytes; v128 globals
   occupy 16 bytes with 16-byte alignment (pad the running
   offset up to a multiple of 16 before placing a v128
   global). This table is owned by `runtime.Module` (Zone
   1) and survives as long as the module.

2. **Runtime byte buffer**. Replace
   `Runtime.globals_storage: []Value` with
   `Runtime.globals_byte_storage: []u8` aligned to 16
   bytes. Defined globals' initial values land at the
   computed offsets. The existing
   `Runtime.globals: []*Value` aliasing layer is
   **retained for scalar globals only** — i32/i64/f32/f64
   slots are accessible via the existing pointer-per-entry
   path. v128 globals do NOT participate in the
   pointer-per-entry layer at this chunk; v128 imports
   return `UnsupportedImport` at instantiation. The
   import-aliasing extension is tracked as a follow-up
   debt entry (see Consequences).

3. **JitRuntime extension**. `JitRuntime` gains one new
   field, `globals_byte_base: [*]u8`, set at
   `Runtime.toJitRuntime` to
   `Runtime.globals_byte_storage.ptr`. The existing
   `globals_base: [*]Value` is **retained** unchanged so
   the i32 / scalar global emit paths keep working (no
   forced migration). ARM64 keeps `X23` pointing at
   `globals_base`; the v128 emit path loads
   `globals_byte_base` into a scratch register on demand
   (or reserves a new invariant register if hot — TBD by
   §9.9-h-2 measurement).

4. **JIT op handlers**. Add `emitV128GlobalGet` /
   `emitV128GlobalSet` to both
   `src/engine/codegen/arm64/op_globals.zig` and
   `src/engine/codegen/x86_64/op_globals.zig`. At codegen
   time, look up `module.globals_offsets[idx]` (compile-
   time constant per global access), bake it as an
   immediate displacement. ARM64 uses `LDR Q<dst>, [X<base>,
   #off]` / `STR Q<src>, [X<base>, #off]` (imm12 scaled by
   16; max displacement 16*4095 = 65520 → ~4095 v128
   globals fit imm12; beyond that, escalate via materialised
   address synthesis, same shape as existing memory ops).
   x86_64 uses `MOVUPS XMM<dst>, [R<scratch> + off32]` /
   `MOVUPS [R<scratch> + off32], XMM<src>` (full 32-bit
   displacement; effectively unbounded for Wasm modules).

5. **Dispatch routing**. The validator / lowerer already
   produces typed `global.get N` / `global.set N` ZIR ops;
   the dispatch table arm for `.global_get` / `.global_set`
   gets a per-valtype switch on `module.globals[idx].valtype`,
   routing v128 to the new emit functions while
   scalar/i32 keeps the existing path.

6. **Constant evaluation**. `runtime/instance/instantiate.zig:
   evalConstExprValue` extends to handle `0xFD 0x0C`
   (v128.const) by returning a tagged result the caller
   can route into the byte-storage. Practical shape: split
   into `evalConstScalarValue` (returns `Value`) and
   `evalConstV128Value` (returns `[16]u8`); the globals
   instantiation loop dispatches on the global's valtype
   before calling the appropriate evaluator.

## Alternatives considered

### Alternative A — Widen `Value` union to 16 bytes (industry-uniform)

- **Sketch**: Make `Value` a 16-byte extern union with a
  v128 field; uniform 16-byte stride for all globals;
  matches wasmtime/wasmer's industry pattern (2/4 JIT
  runtimes surveyed).
- **Why rejected**:
  1. **W54-class implicit-contract sprawl** (§P2). The
     `@sizeOf(Value) == 8` invariant is asserted by
     `value.zig:90` and consumed by interp dispatch, host_
     calls marshaling, regalloc slot sizing, and ZIR
     payload encoding. Widening forces every consumer to
     either accept the 2x slot cost or learn to dispatch on
     valtype — exactly the kind of pervasive change v2's
     "type up-front" design was set up to avoid.
  2. **Cold-start cost** (§P3). Doubling every scalar
     global's storage doubles the module-instantiation
     memory footprint for modules that don't use v128
     globals — most of them. Variable-stride storage costs
     a one-time `globals_offsets` table (4 bytes per
     defined global) instead.
  3. **Test cost**. Every fixture / test that asserts
     `@sizeOf(Value)`, `globals_storage[idx].i32` shape, or
     the 8-byte slot layout needs migration. Estimate:
     50+ test sites. The migration would touch every
     phase's regression coverage, risking churn.

### Alternative B — Side-table for v128 globals (parallel `[]V128` storage)

- **Sketch**: Keep `Value` at 8 bytes; add a parallel
  `v128_globals_storage: []V128` (and `v128_globals: []*V128`
  for cross-module). Per-global mapping records "kind" +
  "sub-index" so global N's storage is either
  `globals_storage[sub]` or `v128_globals_storage[sub]`.
- **Why rejected**:
  1. **Two parallel pointer-per-entry layers** doubles the
     complexity of the cross-module aliasing path
     (ADR-0014 §2.1 / 6.K.1). When v128 imports eventually
     land, both layers need synchronised wiring.
  2. **JIT codegen needs two base pointers** (scalar +
     v128) in invariant registers OR per-access reloads —
     more register pressure on ARM64's already-tight
     callee-saved budget (ADR-0027 took the 6th register
     for `globals_base`; this would want a 7th for
     `v128_globals_base`).
  3. **Industry-divergent** (0/4 surveyed runtimes).
     Future contributors familiar with wasmtime's VMOffsets
     pattern would not recognise the shape; Option C's
     per-valtype offsets at least matches wasmtime's
     conceptual model (precomputed offsets per global)
     even though the implementation differs in keeping
     `Value` narrow.

### Alternative D — Defer v128 globals to Phase 10+ entirely

- **Sketch**: Mark `simd_const.388` as a skip-fixture with
  an ADR + debt entry; leave Mac at 11263/4 (residual
  v128-globals-related fails); discharge in Phase 10+
  alongside imports + ref.func extensions.
- **Why rejected**:
  1. **§9.9 exit criterion** is `fail = skip = 0 on the
     3-host gate`. Skipping the fixture trades one form of
     "not zero" for another — the §9.9 row stays `[ ]`
     either way.
  2. The fix is structurally bounded by this ADR (one
     ABI choice + 6 concrete code-change sites);
     deferring is procrastination, not de-scoping.
  3. Per `.claude/rules/extended_challenge.md`, an
     "absence" must be demonstrably structural to defer.
     Here the work is well-bounded and the survey already
     landed; deferral fails the "provably unsolvable"
     bar.

## Consequences

### Positive

- **Value union stays 8 bytes.** Existing `value.zig:90`
  invariant + every consumer of `Value` (interp dispatch,
  host_calls, ZIR payload, regalloc slot sizing) is
  unaffected. No 50-site test migration.
- **Forward-compatible with imports.** `globals_offsets`
  table is the natural place to record per-global metadata
  (valtype, mutability, source-instance pointer for
  imports). Phase 8+ cross-module v128 import wiring
  extends the table without disturbing the JIT emit
  shape.
- **Industry-aligned at the conceptual layer.** Wasmtime's
  VMOffsets and wasmer's vmoffsets both precompute per-
  global byte offsets at module load; v2's pattern is the
  same shape, differing only in keeping `Value` narrow
  rather than widening. New contributors transferring
  from wasmtime will find the precomputed-offset pattern
  recognisable.
- **Per-module memory footprint shrinks.** Modules with no
  v128 globals pay zero extra storage (offsets equal
  `idx * 8` exactly; same as today). Modules with v128
  globals pay 16 bytes per v128 global plus one u32 per
  defined global for the offsets table.

### Negative

- **JitRuntime layout grows by 8 bytes** (one new pointer
  field). Acceptable per ADR-0027's existing budget
  reasoning; total `JitRuntime` size remains well under
  the imm12 ceiling.
- **Dispatch routing complexity.** The dispatch arm for
  `.global_get` / `.global_set` becomes a switch on
  valtype rather than a single emit call. Mitigation: the
  switch lives entirely in `dispatch_table.zig`'s arm; the
  per-arch op_globals files keep their per-handler
  shape.
- **ARM64 imm12 budget for v128 globals**: Q-form LDR/STR
  imm12 scales by 16 with max 4095 → ~4095 v128 globals
  fit immediate-form addressing. Beyond that, escalate to
  materialised address synthesis (same pattern as memory
  ops). Hard to imagine a Wasm module with 4000+ v128
  globals, but the encoder must error cleanly past the
  ceiling.
- **No v128 import resolution at this chunk.** Modules
  that `(import "env" "g" (global v128))` fail
  instantiation with `UnsupportedImport`. Tracked as a
  follow-up debt entry (D-079, queued at task close); the
  immediate use case (simd_const.388) is self-contained
  and doesn't exercise imports.

### Neutral / follow-ups

- **ADR-0027 Revision history amendment**: when the v128
  globals implementation chunk lands, append a row to
  ADR-0027 documenting the Alternative C activation +
  the JitRuntime extension. ADR-0027 stays the
  authoritative ABI source; this ADR is the rationale
  layer.
- **D-078 (b) debt entry** narrows to: "implemented per
  ADR-0052; closes simd_const.388 runtime fails on Mac
  aarch64". The OrbStack runtime path is the symmetric
  follow-up.
- **D-079 (new debt entry, queued at task close)**:
  v128 global imports — extends the
  `globals_offsets` table + `globals: []*Value`
  aliasing layer to handle cross-module v128 imports.
  Out of scope for the current chunk; tracked structural
  follow-up for Phase 10+ import work.

## References

- ROADMAP §1, §2 P2 (W54 anti-sprawl), §2 P3 (cold-start),
  §4 (architecture)
- ADR-0027 (JitRuntime globals extension; this ADR
  activates its deferred Alternative C)
- ADR-0017 (JitRuntime ABI; consumes the new
  `globals_byte_base` field)
- ADR-0026 (x86_64 invariant strategy; v128 emit follows
  the same reload-from-runtime-ptr pattern)
- ADR-0041 (SIMD-128 SSE4.2 baseline; defines the v128
  scope this ADR's JIT emit consumes)
- ADR-0046 (v128 calling convention; defines how v128
  values flow between Wasm function calls — this ADR
  extends the storage layer with the same valtype-aware
  dispatch shape)
- Survey: `private/notes/p9-v128-globals-survey.md`
  (gitignored, informal)
- wasmtime: `~/Documents/OSS/wasmtime/crates/environ/src/
  vmoffsets.rs` lines 936–1026
- wasmer: `~/Documents/OSS/wasmer/lib/types/src/
  vmoffsets.rs` lines 614–628
- Failing fixture:
  `test/spec/wasm-2.0-simd-assert/simd_const/simd_const.388.wasm`

## Revision history

| Date       | SHA          | Note                          |
|------------|--------------|-------------------------------|
| 2026-05-11 | `02f64c5c` | Initial accepted version (rationale-only; implementation lands at §9.9-h-2). |
