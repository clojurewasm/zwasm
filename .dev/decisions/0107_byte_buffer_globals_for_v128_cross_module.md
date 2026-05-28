# 0107 — Migrate `Runtime.globals` to byte-buffer for v128 cross-module support

- **Status**: Withdrawn 2026-05-24 — superseded by ADR-0110 (Value widen to 16-byte). The "byte-buffer globals propagation to c_api" goal is root-cause-fixed by ADR-0110's Value=16 widen (uniform 16-byte Value = no per-valtype offsets needed anywhere = no c_api byte-buffer propagation needed). Stays in-tree as design-decision lineage (per ADR-0108 Withdrawn pattern). See ADR-0110 §Context for the reframe rationale + `docs/runtime_deep_comparison.md` §1-2 for the industry-audit data that triggered the reframe.
- **Date**: 2026-05-23
- **Author**: claude (autonomous loop)
- **Tags**: runtime, instance, v128, cross-module, jit-codegen, c_api, D-079

## Context

D-079 (ii) — `Runtime.globals: []*Value` is scalar-only (8-byte
per-slot per ADR-0052 §3 "Negative"); cross-module v128 global
imports via the c_api `wasm_instance_new` / `setupRuntime` path
raise `UnsupportedImport`. Wasm 2.0 globals can be v128 (16
bytes); the spec runner-side path discharged at §9.12-E
`b11314ff` via `GlobalsCtx` (offsets + valtypes + byte buffer),
but the c_api Instance path still uses the legacy scalar
`*Value` layer.

ADR-0104 promoted D-079 (ii) to Phase 9 真スコープ. Discharge
requires structural migration of `Runtime.globals`.

JIT-side codegen ALREADY supports v128 globals via byte-offset
load/store: `src/engine/codegen/arm64/op_globals.zig::emitV128GlobalGet/Set`
(lines 208+/234+) reads `[X23 + ctx.globals_offsets[idx]]` with
Q-form LDR/STR. x86_64 mirrors via xmm load/store at the same
byte offset shape. The blocker is host-side: setup.zig +
instantiate.zig allocate `globals: []Value` (8-byte stride) and
wire imports under the assumption of fixed-width scalar slots.

## Decision

Migrate the host-side `Runtime.globals` representation from
`[]*Value` (scalar-only, 8-byte slots) to a byte-buffer with
per-entry offsets + valtypes, mirroring the spec runner's
`GlobalsCtx`:

```zig
// Runtime fields (proposed):
globals_buf: []u8 align(16),         // contiguous bytes
globals_offsets: []u32,              // per-global byte offset into globals_buf
globals_valtypes: []zir.ValType,     // per-global declared type (v128 = 16 B, others = 8 B)
globals_count: u32,                  // total = imports + defined
```

Scalar globals occupy 8 bytes; v128 globals occupy 16 bytes
with 16-byte alignment. JIT codegen path stays unchanged (it
already reads via `[globals_base + byte_off]`); the `*Value`
shape disappears.

Cross-module v128 import wiring in `instantiate.zig` allocates
v128 slots at the importer's `globals_offsets[i]` and copies
the source runtime's v128 bytes at instantiate time (or aliases
the source's buffer slice for the imported slot — both work
since cross-module global imports are immutable in Wasm 2.0).

## Alternatives considered

### Alternative A — Add `v128: [16]u8` variant to `Value` union

- **Sketch**: Extend `Value` from `extern union` to a wider
  layout that includes a v128 variant.
- **Why rejected**: `Value` is the JIT's per-slot value type;
  widening to 16 bytes doubles the stack/locals/operand cost
  for ALL slots (not just v128 ones). The JIT stack discipline
  per ADR-0014 assumes 8-byte slots; cascading change.

### Alternative B — Parallel `globals_v128: [][16]u8` side buffer

- **Sketch**: Keep `globals: []*Value` scalar; add a parallel
  `globals_v128` storage with a separate index space, mapped
  via `globals_kind[]: enum {scalar, v128}`.
- **Why rejected**: Forks the global access path in JIT codegen
  (two different byte_off shapes depending on kind); diverges
  from spec runner's already-converged byte-buffer model;
  doubles the JIT prescan logic for global ops. Cleaner to
  unify on the byte-buffer model the spec runner already uses.

### Alternative C — Defer to v0.2 (status quo)

- **Sketch**: Keep `UnsupportedImport` error for v128
  cross-module imports; close D-079 (ii) as "won't fix in v0.1".
- **Why rejected**: ADR-0104 promoted D-079 (ii) to Phase 9
  真スコープ. The user direction at 2026-05-23 was "windows
  以外を片付けて" — D-079 (ii) is the only remaining structural
  §5.3a item. Deferring contradicts Phase 9 = DONE eligibility.

### Alternative D — Fixed 16-byte per-global cell (wasmtime model)

- **Sketch**: All globals are 16-byte cells regardless of declared
  type; indexing is `globals_buf + i*16`. Cast helpers reinterpret
  the cell as i32/i64/f32/f64/v128/funcref/externref at access
  sites. Wasm modules typically have ≤ 10 globals so the 8-byte-
  per-scalar waste is negligible (~80 bytes per module).
- **Precedent**: `wasmtime/crates/wasmtime/src/runtime/vm/vmcontext.rs:491+`
  `VMGlobalDefinition { storage: [u8; 16] }` with `as_i32()` /
  `as_v128()` / `set_u128()` cast helpers + alignment asserts
  at lines 513-519. Cross-module wiring at
  `imports.rs` threads `VmPtr<VMGlobalDefinition>` for imported
  globals (16-byte alignment preserved across boundary).
- **Counter-precedent**: zware `src/store/global.zig` uses
  `value: u64` (scalar-only; v128-incapable — same shape as
  zwasm v1 pre-D-079).
- **Why rejected for v2**: The spec runner's `GlobalsCtx` at
  §9.12-E `b11314ff` already converged on variable per-entry
  byte offsets (`globals_offsets[]` + `globals_valtypes[]`),
  and JIT-codegen reads via `[globals_base + ctx.globals_offsets[idx]]`
  (per-entry offset lookup). Switching to fixed 16-byte stride
  would require refactoring BOTH the spec runner AND JIT codegen
  for marginal memory savings (~80 bytes/module). The variable-
  offset model also matches arm64's Q-form / x86_64's xmm load
  alignment naturally (16-byte alignment required for v128
  slots; scalars at 8-byte slots satisfy their alignment).
  Fixed-cell is the cleaner alternative for a greenfield runtime;
  for v2 mid-Phase-9, converging on the existing `GlobalsCtx`
  shape is structurally cheaper.

## Consequences

- **Positive**: Single global access model across spec runner +
  c_api Instance + JIT codegen; v128 cross-module imports work;
  ADR-0052 §3's scalar-only restriction lifted.

- **Negative**: Touches ~13 callsites across `validator.zig` /
  `interp/mvp.zig` / `instantiate.zig` / `api/instance.zig` +
  `setup.zig` globals_buf allocation + `jit_abi.zig`
  `globals_base` type change. JIT-codegen changes minimal
  (already byte-buffer-style); host-side changes substantial.
  Estimated 2-3 implementation cycles.

- **Implementation hazards** (cycle 34 spike-equivalent
  investigation per `/continue` SKILL.md autonomous-prep
  walk; reviewed actual code state in lieu of throwaway
  prototype since spec runner's `GlobalsCtx` already proves
  the design at `src/engine/runner_validate.zig:163`):
  1. **validator.zig's `globals: []ImportGlobal` is a
     SEPARATE list** from `Runtime.globals` (compile-time
     module state vs runtime store). The migration must NOT
     conflate them — only `Runtime.globals` (host-side
     store) changes; validator-side stays as-is.
     Callsites at `validator.zig:815, 821` are unaffected.
  2. **`globals_storage: []Value` is a separate backing
     buffer** at `instantiate.zig:690`, parallel to
     `Runtime.globals: []*Value`'s pointer-to-element layer.
     The byte-buffer migration consolidates BOTH into a
     single `globals_buf: []u8 align(16)`; the storage-vs-
     slot split disappears.
  3. **c_api cross-module aliasing** at
     `api/instance.zig:512` currently stores
     `*Value` pointer (= aliases source instance's slot).
     Byte-buffer migration must choose between (a) slice
     view aliasing (`source.globals_buf[off..off+width]`)
     or (b) byte copy at instantiate time (matches spec
     runner's `applyImportedGlobalsFromRegistered`). Both
     are correct for Wasm 2.0 (immutable cross-module
     globals); the copy approach matches the
     already-converged spec-runner pattern. Future Wasm
     proposal for mutable shared globals would re-open this
     choice.
  4. **`interp/mvp.zig:728` does `rt.globals = &slots`** —
     local-scope slice assignment for spectest scaffolding.
     Migration changes the slice type; mechanical rewrite
     (`rt.globals_buf = &storage_bytes` + offsets/valtypes
     initialised inline). Trivial.

  Net assessment: NO design change to ADR-0107 needed; the
  4 hazards are mechanical-callsite-level concerns that
  surface during implementation, not design-time blockers.
  Spike outcome = "design verified by existing GlobalsCtx
  precedent + reviewed implementation hazards".

- **Neutral / follow-ups**:
  - `setup.zig::createOwned` updated to compute byte buffer
    size from compiled.globals_byte_size (already calculated
    via `computeGlobalsLayout`).
  - `interp/mvp.zig` global.get/set updated to read via
    byte-buffer + offsets (matching JIT shape).
  - `applyDefinedGlobalsInit` already byte-buffer-aware (used
    by spec runner); just route through the same helper from
    c_api setupRuntime.
  - D-079 (ii) row in `.dev/debt.md` flipped from `now` to
    `blocked-by: ADR-0107 Accept` until this ADR flips
    Accepted.

## References

- ROADMAP §9 (Phase 9 真スコープ scope per ADR-0104).
- Related ADRs:
  - ADR-0052 §3 ("Negative") — scalar-only restriction this
    ADR lifts.
  - ADR-0104 — Phase 9 真スコープ scope expansion.
  - ADR-0027 — `globals_base` 8-byte slot assumption (to be
    amended).
  - ADR-0061 — reftype 8-byte slot (orthogonal, stays).
- Debt: D-079 (ii) — `.dev/debt.md`.
- Spec runner byte-buffer model:
  `src/engine/runner_validate.zig::GlobalsCtx` +
  `applyImportedGlobalsFromRegistered` +
  `applyDefinedGlobalsInit`.
- JIT codegen (already byte-buffer):
  `src/engine/codegen/arm64/op_globals.zig` /
  `src/engine/codegen/x86_64/op_globals.zig`.
- External-runtime precedents (Alternative D ref enrichment,
  cycle 32 autonomous prep walk per `/continue` SKILL.md):
  - `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/vmcontext.rs:491+`
    `VMGlobalDefinition` (fixed 16-byte cell model).
  - `~/Documents/OSS/zware/src/store/global.zig` (scalar-only
    counter-precedent; v128-incapable).

<!--
## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-23 | `6b3c6705` | Initial Proposed.                       |
| 2026-05-23 | `321edbba` | Cycle 32 enrichment — added Alternative D (wasmtime fixed-16-byte-cell model) + zware scalar-only counter-precedent. Per `/continue` SKILL.md autonomous-prep walk for user-gated ADRs. |
| 2026-05-23 | `ad89fa0b` | Cycle 34 spike-equivalent investigation — reviewed actual code state at validator.zig:815, instantiate.zig:690/700, api/instance.zig:512, interp/mvp.zig:728; surfaced 4 implementation hazards (validator/Runtime split, globals_storage consolidation, c_api aliasing choice, mvp.zig slice rewrite). Outcome: design verified by existing GlobalsCtx precedent; no ADR changes needed; hazards documented for impl reference. |
-->
