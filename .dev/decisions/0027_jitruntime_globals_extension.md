# 0027 — Extend JitRuntime with `globals_base` + `globals_count` for Wasm globals access

- **Status**: Closed (Phase 7 DONE)
- **Date**: 2026-05-05
- **Author**: zwasm-from-scratch loop (chaploud)
- **Tags**: jit, abi, runtime, globals

## Context

§9.7 / 7.7-globals chunk introduces `global.get` / `global.set`
emit handlers on both ARM64 and x86_64 backends. The access path
needs a clean way to reach the globals array from within JIT-
compiled code. Two structurally different choices exist:

- **A (JitRuntime extension)**: Add `globals_base: [*]Value`
  to `JitRuntime` (Zone 1: `src/engine/codegen/shared/jit_abi.zig`),
  read at `[R15 + globals_base_off]` (x86_64) or via a 6th
  callee-saved invariant register (ARM64).
- **B (Instance direct access)**: Pass globals via a separate
  pointer or vtable threaded outside `JitRuntime`. Breaks
  ADR-0026's "all instance invariants via runtime_ptr" principle
  for x86_64.

The decision blocks 7.7-globals chunk start; it has direct
implications for ADR-0017 (JitRuntime layout), ADR-0018 (ARM64
register reservation), and ADR-0026 (x86_64 invariant strategy).

A cross-runtime survey (per `.claude/rules/textbook_survey.md`)
covering wasmtime/cranelift, wasmer (singlepass), wazero, WAMR,
wasm3, zware, and zwasm v1 was conducted in
`private/notes/p7-7.7-globals-survey.md` (informal notes; not
load-bearing). Key findings:

| Runtime | Layout | Access path |
|---|---|---|
| wasmtime/cranelift | `[VMGlobalDefinition; N]` inlined in VMContext | `[vmctx + vmctx_globals_begin() + idx*16]` (16B per global) |
| wasmer (singlepass) | `[VMGlobalDefinition; N]` inlined in instance | `[vmctx_reg + vmctx_vmglobal_definition(idx)]` |
| wazero | `[]Value` slice on Module Instance | `instance.globals[idx]` (interpreter; JIT path mirrors) |
| WAMR (AOT) | `globals_data` flat buffer in module instance | `[instance.globals_data + offset]` (pre-computed) |
| wasm3 | `M3Global` array union of i32/i64/f32/f64/funcref | direct field deref (interpreter only) |
| zware | `ArrayList(Global)` in Store | `&store.globals.items[globaladdr]` |
| zwasm v1 | per-global helper call `jitGlobalGet(instance, idx)` | function call, ~20 cycles per access |

**Industry pattern: 100% (6/6) of JIT-bearing runtimes embed
globals inline within their vmctx-equivalent structure and
access via `[vmctx + offset]`.** None use a separate vtable or
secondary pointer. zwasm v1's per-global helper call is an
outlier with a measurable per-access cost penalty.

## Decision

**Adopt Alternative A (JitRuntime extension).** Extend
`JitRuntime` (Zone 1, `src/engine/codegen/shared/jit_abi.zig`)
with two new fields in the existing extern struct layout:

```zig
pub const JitRuntime = extern struct {
    vm_base: [*]u8,                  // 0
    mem_limit: u64,                  // 8
    funcptr_base: [*]const u64,      // 16
    table_size: u32,                 // 24
    _pad0: u32,                      // 28
    typeidx_base: [*]const u32,      // 32
    trap_flag: u32,                  // 40
    _pad1: u32,                      // 44
    globals_base: [*]const Value,    // 48 ← NEW (8 byte pointer)
    globals_count: u32,              // 56 ← NEW (bounds check)
    _pad2: u32,                      // 60
};
```

`Value` here is the existing `runtime/value.zig` 16-byte tagged
union (same width regardless of i32/i64/f32/f64/v128 contained
type). Per-global byte offset within `globals_base` is therefore
`idx * @sizeOf(Value)` — no per-module offset table required at
this phase.

**ARM64**: pre-load `globals_base` into a 6th callee-saved
invariant register at function prologue (recommended X23 per
ADR-0018 reservation pattern). This grows the reservation set
from 5 → 6 GPRs (X28, X27, X26, X25, X24, X23). Of AAPCS64's
10 callee-saved GPRs (X19-X28), 4 remain unreserved after this
change (X19, X20, X21, X22) — sufficient headroom for ADR-0017
extensions through Phase 8.

**ARM64 emit shape**: `LDR Rd, [X23, Ridx, LSL #4]` (register-
offset, scale=16 = `@sizeOf(Value)`). Register-offset addressing
**bypasses imm12 immediate-offset limits entirely**, so the
~256-global ceiling that an immediate-offset shape would impose
(`STR/LDR ..., [Xn, #imm12]` where imm12 max = 4095 / 16 = 255
globals) is non-applicable. globals_count is bounded only by the
Wasm spec's u32 index space.

**ARM64 prescan**: a function with no `global.get` / `global.set`
instructions skips the X23 prologue load (parallel to ADR-0026's
x86_64 prescan for `uses_runtime_ptr`). globals_count == 0 modules
similarly skip the load even when statically scanned.

**x86_64**: per ADR-0026's "single reservation + reload-from-
runtime-ptr" model, `global.get` / `global.set` emit:

```
MOV R<scratch>, [R15 + globals_base_off]   ; reload globals_base
MOV R<dst>, [R<scratch> + idx * sizeof(Value)]  ; the actual access
```

This is the same shape as memory ops (`emitMemOp` reloads
vm_base into RAX from `[R15 + vm_base_off]`).

`globals_count` enables bounds-checked global access (parallels
`mem_limit`) for future feature work; not required for Wasm
1.0 spec since global indices are statically validated at
module load. Keep the field for forward compatibility (Phase 11
gc proposal exposes runtime-typed globals where dynamic indexing
becomes possible).

## Alternatives considered

### Alternative B — Instance direct access (separate vtable)

- **Sketch**: Add `globals_ptr: [*]const Value` + `globals_len:
  u32` as a `GlobalsVtable` struct, passed at JIT entry as a
  second argument (RDI/X1 alongside the runtime_ptr in RDI/X0).
  Or threaded as `JitRuntime.globals_vtable: *const
  GlobalsVtable`.
- **Why rejected**:
  1. Breaks ADR-0026's "all x86_64 invariants reach via R15"
     principle; introduces a second indirection (R15 → vtable →
     globals_base).
  2. Industry-divergent: 0/6 surveyed JIT runtimes use a
     separate vtable for globals.
  3. ARM64 either consumes another callee-saved register (same
     cost as Alternative A) or requires a per-call reload
     (worse than Alternative A's prologue-once cost).
  4. Cross-call instance switching becomes more complex (call
     boundary needs to swap two pointers atomically rather
     than just R15).
  5. Conceptual asymmetry with memory/table/funcptr access
     (which all live inside JitRuntime).

### Alternative C — Pre-computed per-global byte offsets in a module-level VMOffsets table (wasmtime/wasmer pattern)

- **Sketch**: At module load, build a `globals_offsets: []u32`
  table mapping global_idx → byte offset within the globals
  array (allowing variable-width per global if SIMD globals
  are inlined differently from i32 globals). JIT emits use the
  pre-computed offset at codegen time.
- **Why rejected** (deferred, not killed):
  1. zwasm v2 currently uses uniform 16-byte `Value` (extern
     union per `value.zig`) for all global types; the constant
     `idx * @sizeOf(Value)` arithmetic is already pre-computed
     at codegen and doesn't need an external table.
  2. wasmtime's VMOffsets exists primarily to handle the mix
     of inline + imported globals (imported globals are
     pointer-to-pointer). zwasm v2 import wiring is post-MVP
     (`runtime/instance/import.zig` ImportBinding landed but
     full cross-module invocation is deferred to Phase 8+
     per ROADMAP §9.8).
  3. **Forward-compatibility**: when imports + SIMD-aligned
     globals land, this Alternative C becomes the natural
     evolution. The `globals_base + globals_count` shape
     does not preclude it.

### Alternative D — Per-call helper function (zwasm v1 pattern)

- **Sketch**: `jitGlobalGet(rt: *JitRuntime, idx: u32) Value`
  callable from JIT-compiled code via System V ABI.
- **Why rejected**:
  1. v1 measured ~20 CPU cycles per access (full helper call
     prologue + body + return). Industry inline access is
     1–2 cycles.
  2. ROADMAP P3 (cold-start performance) and P5 (per-op
     latency) explicitly favour inline emit over helper call
     for hot ops. global.get is hot in stateful workloads
     (every closure invocation reads multiple globals).
  3. Forces caller-saved spilling at every global access
     (helper call clobbers caller-saved registers).
  4. Inferior compatibility with W54-class postmortem: helper
     call obscures the actual op site in trace output; ADR-
     0028 trace ringbuffer would be unable to attribute a
     trap to a specific global access without unwinding the
     helper frame.

## Consequences

### Positive

- **Industry alignment**: the choice mirrors wasmtime, wasmer,
  wazero, WAMR, and zware (5/6 surveyed runtimes; the 6th is
  wasm3 which is interpreter-only). New contributors familiar
  with any major Wasm JIT will find the shape immediately
  recognisable.
- **ADR-0026 conformity**: x86_64 path keeps "all instance
  invariants reach via R15", preserving the single-reservation
  architectural claim.
- **Single emit pattern**: `global.get` reads `[R<scratch>,
  R<scratch> + idx*sizeof(Value)]` (x86_64) or `LDR Rd, [X23,
  Ridx LSL #4]` (ARM64), same shape as memory ops.
- **Forward compatibility**: `globals_count` field reserved
  for runtime-typed globals (gc proposal Phase 11+); the field
  costs 4 bytes per JitRuntime (negligible).

### Negative

- **JitRuntime size grows from 48 → 64 bytes** (16-byte
  alignment to next cache line boundary). One additional 64-
  byte cache line per JitRuntime allocation. Acceptable: a
  JitRuntime is per-Instance, and Instances are created at
  module instantiation (cold path).
- **ARM64 reservation grows from 5 → 6 GPRs** (X28, X27,
  X26, X25, X24, **X23**). AAPCS64 callee-saved GPRs are
  X19-X28 (10 total; X29=FP, X30=LR are role-fixed). After
  this change 4 callee-saved remain unreserved (X19, X20,
  X21, X22). The regalloc pool also draws from caller-saved
  X0-X17 (16 caller-saved GPRs free within a compiled Wasm
  function body modulo IP0=X16/IP1=X17 mid-op scratch usage),
  so the effective per-function pool is not bottlenecked by
  the new X23 reservation.
- **x86_64 per-access reload cost**: every `global.get` /
  `global.set` emits an extra `MOV R_scratch, [R15 +
  globals_base_off]` (7 byte instruction). Mitigation: same
  pattern as memory ops; ADR-0026 already accepts this trade
  for x86_64. A future optimisation phase (Phase 8 / Phase
  15) could hoist the reload to the function prologue when
  multiple global accesses are present (analogous to the
  liveness-driven hoisting deferred in ADR-0026 § "Pool
  sizing").

### Neutral / follow-ups

- **ADR-0017 Revision history amendment**: when 7.7-globals
  chunk lands, append a Revision history row to ADR-0017
  documenting the JitRuntime layout extension (do NOT update
  the body in this ADR; ADR-0017 stays the authoritative
  layout source, this ADR is the rationale).
- **ADR-0018 Revision history amendment**: ARM64 reservation
  set 5 → 6 needs a row; the new X23 invariant slot.
- **ADR-0026 cross-reference**: x86_64 path explicitly
  documents the `globals_base` reload as an instance of the
  ADR-0026 "reload-from-runtime-ptr" pattern; add a row to
  ADR-0026 Revision history when 7.7-globals lands.
- **VMOffsets table introduction (Alternative C)** is the
  natural successor when imported globals + SIMD globals
  land. Tracked as a follow-up debt entry once the immediate
  use case (gc / SIMD globals) is in scope.

## References

- ROADMAP §1 (mission), §2 P3 (cold-start), §2 P5 (per-op
  latency), §4 (architecture), §10 (consumer surface)
- ADR-0017 (JitRuntime ABI; this ADR extends layout)
- ADR-0018 (ARM64 register reservation; this ADR adds X23)
- ADR-0026 (x86_64 invariant strategy; this ADR follows the
  "reload-from-runtime-ptr" pattern)
- Cross-runtime survey: `private/notes/p7-7.7-globals-survey.md`
  (informal; not load-bearing)
- wasmtime: `~/Documents/OSS/wasmtime/crates/cranelift/src/
  func_environ.rs` lines 2989–3000
- wasmer: `~/Documents/OSS/wasmer/lib/compiler-singlepass/src/
  codegen.rs` lines 1101–1105
- zwasm v1 (anti-pattern reference): `~/Documents/MyProducts/
  zwasm/src/x86.zig:emitGlobalGet` (helper-call shape;
  re-derive don't copy per `.claude/rules/no_copy_from_v1.md`)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-05 | `618ac144` | Initial accepted version (#5 of 7-issue cleanup batch) |
| 2026-05-06 | `f55ddb99` | Implementation landed (i32 globals only): JitRuntime extended (48→64 byte) with `globals_base` + `globals_count`. ARM64 X23 reserved as `globals_base_save_gpr` (allocatable_callee_saved 4→3, total reserved 6→7). x86_64 reload-from-runtime-ptr at `[R15 + globals_base_off=48]`. Per-global stride confirmed = `@sizeOf(Value) = 8` (not 16; revised down from initial Decision text). i64/f32/f64 globals deferred to next chunk. |
