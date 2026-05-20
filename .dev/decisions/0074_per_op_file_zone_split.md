# 0074 — Split the per-op file across Zone 1 and Zone 2 along the axis boundary

- **Status**: Accepted
- **Date**: 2026-05-19
- **Author**: autonomous /continue loop (§9.12-B / B9)
- **Tags**: architecture, zone, dispatch, instruction, codegen

## Context

ADR-0023 §4.5 amend (2026-05-19, accepted at §9.12 collab gate close)
established the **per-op file pattern**: every `ZirOp` tag gets a
single file `src/instruction/wasm_X_Y/<op>.zig` exporting the
canonical 5-axis handler aggregate:

```zig
pub const handlers = .{
    .validate = validate_<op>,
    .lower    = lower_<op>,
    .arm64    = emit_arm64_<op>,
    .x86_64   = emit_x86_64_<op>,
    .interp   = interp_<op>,
};
```

ADR-0023 §4.5's worked example shows the handler signatures as
`fn emit_arm64_<op>(ctx: *Arm64EmitCtx) !void`, where `Arm64EmitCtx`
is the per-arch emit workspace defined at
`src/engine/codegen/arm64/ctx.zig`.

`src/instruction/` is classified as **Zone 1** by both ROADMAP §4.1
and `.claude/rules/zone_deps.md`:

```
Zone 1: src/ir/, src/runtime/, src/parse/, src/validate/,
        src/instruction/, src/feature/, src/diagnostic/
Zone 2: src/interp/, src/engine/, src/wasi/
```

The `zone_deps.md` "NEVER: upward imports" rule forbids Zone 1 from
importing Zone 2. `Arm64EmitCtx` and `X86_64EmitCtx` live in Zone 2.
Therefore a Zone 1 per-op file **cannot** contain an arm64/x86_64
handler whose body actually references the codegen ctx — it can only
contain a stub.

§9.12-B / B1..B8 landed with stub handlers
(`fn() DispatchError!void { return error.NotMigrated; }`) precisely
because the conflict had not been resolved. B9..Bn cannot proceed
with real arm64/x86_64 body migration until the zone direction is
sorted.

Comptime DCE (the load-bearing goal of ADR-0073) requires the
handler bodies to be visible at the dispatcher's call site so the
`inline switch` arms can be statically pruned. Runtime function
pointers would forfeit DCE.

## Decision

**Split the per-op file across two zones along the axis boundary.**

| Axis     | Zone | Path                                                            |
|----------|------|-----------------------------------------------------------------|
| validate | 1    | `src/instruction/wasm_X_Y/<op>.zig`                             |
| lower    | 1    | `src/instruction/wasm_X_Y/<op>.zig`                             |
| interp   | 1    | `src/instruction/wasm_X_Y/<op>.zig`                             |
| arm64    | 2    | `src/engine/codegen/arm64/ops/wasm_X_Y/<op>.zig`                |
| x86_64   | 2    | `src/engine/codegen/x86_64/ops/wasm_X_Y/<op>.zig`               |

The Zone 1 file remains the **identity anchor** for the op: it
exports `op_tag`, `wasm_level`, `wasi_level`, `enable_features`, and
the IR-axis handlers (validate / lower / interp). The Zone 2 sibling
files import the Zone 1 file (allowed direction) to read `op_tag` for
their own metadata, then export the arm64 / x86_64 handlers using
the codegen ctx types freely.

`src/ir/dispatch_collector.zig` (Zone 1) keeps the IR-axis dispatcher
+ metadata collection. A **second collector** lives at Zone 2:
`src/engine/codegen/dispatch_collector.zig` (new) imports both the
Zone 1 per-op metadata and the Zone 2 per-arch op files; it builds
the comptime `inline switch` dispatchers for the arm64 and x86_64
axes.

Both collectors filter by the same `build_options.wasm_level` /
`wasi_level` (read from the Zone 1 per-op file's metadata), so DCE
applies uniformly across all 5 axes.

## Alternatives considered

### Alternative A — Move `instruction/` to Zone 2

- **Sketch**: Reclassify `src/instruction/` as Zone 2; per-op files
  freely import codegen ctx types from `engine/codegen/`.
- **Why rejected**: validator and lower (Zone 1) need to call the
  per-op validate / lower handlers. Zone 1 cannot import Zone 2 ⇒
  Zone 1 callers would need a VTable indirection (runtime function
  pointers), forfeiting comptime DCE on the IR axes. Violates
  ADR-0073's literal-absence goal.

### Alternative B — Move codegen ctx types to Zone 1

- **Sketch**: Promote `Arm64EmitCtx` + `X86_64EmitCtx` to Zone 1 so
  per-op files in Zone 1 can reference them.
- **Why rejected**: codegen ctx types own allocator-backed buffers,
  regalloc state, label tables, prologue/epilogue helpers — all
  Zone 2 concerns. Promoting them to Zone 1 collapses the whole
  Zone 1 ↔ Zone 2 boundary; cuts against ROADMAP §4.1.

### Alternative C — Runtime VTable for all 5 axes

- **Sketch**: Per-op file (Zone 1) declares `var handlers:
  Handlers = .{}`; codegen / interp at startup populate function
  pointers.
- **Why rejected**: runtime function pointers defeat comptime
  inline-switch DCE. ADR-0073's primary exit criterion ("verifies
  literal absence of disabled-feature symbols in the linked
  binary") fails by construction.

### Alternative D — Inline encoding in Zone 1

- **Sketch**: Lift every needed `enc*` encoder + `regalloc.alloc*`
  helper into a new Zone 0 / Zone 1 utility module, then per-op
  arm64 handler at Zone 1 inlines the full encoding logic without
  touching `Arm64EmitCtx`.
- **Why rejected**: would duplicate ~74 KB of `engine/codegen/arm64/
  inst.zig` content + most of the regalloc surface. The codegen
  ctx ties allocator, buffer, regalloc, label tables, and prologue
  state together for a reason; teasing them apart is a Phase 11+
  refactor, not a Phase 9 completion task.

### Alternative E — Single per-op file as Zone-1-but-Zone-2-import-allowed

- **Sketch**: Carve out an exception to the zone rules just for
  `src/instruction/`: allow Zone 1 → Zone 2 imports from this
  directory only.
- **Why rejected**: zone rules exist to prevent accidental upward
  coupling; a single-directory exception erodes the discipline
  and invites future creep. The split (this decision) achieves
  the same outcome without bending the layering invariant.

## Consequences

### Positive

- **Comptime DCE preserved for all 5 axes**: each collector is at
  the zone where its handler bodies live, so the `inline switch`
  arms see concrete handler bodies for comptime pruning.
- **Zone direction invariant preserved**: no exception, no Zone 1
  → Zone 2 import. `zone_check.sh --strict` keeps working.
- **Co-naming preserves discoverability**: `i32_add` shows up at 3
  paths (`src/instruction/wasm_1_0/i32_add.zig`,
  `src/engine/codegen/arm64/ops/wasm_1_0/i32_add.zig`,
  `src/engine/codegen/x86_64/ops/wasm_1_0/i32_add.zig`). `find
  . -name 'i32_add.zig'` lists the full op surface.
- **Cohesion at the right granularity**: spec-defined semantics
  (validate / lower / interp) cluster at Zone 1; ISA-specific
  encoding (arm64 / x86_64) clusters at Zone 2. The split matches
  the ROADMAP §4 zone purpose statement.

### Negative

- **1 op = 3 files** (1 metadata + 2 codegen) instead of the
  originally-amended "1 op = 1 file". The ADR-0023 §4.5 amend's
  "1-file = 1-op = full lifecycle visibility" framing weakens
  slightly; mitigated by co-naming.
- **Two `dispatch_collector` files** instead of one, doubling the
  comptime-collector framework code. Mitigated by the shared
  `Axis` enum + shared `enabledByBuild` helper (both at Zone 1,
  imported by Zone 2 collector).
- **Per-arch op file count**: 581 ops × 2 arches = 1162 codegen op
  files. The existing `engine/codegen/arm64/op_*.zig` "category"
  files (`op_alu_int.zig`, `op_simd.zig`, etc.) will be replaced
  by per-op files in `ops/` sub-directory. Substantial diff in
  §9.12-B closing chunks; mitigated by mechanical 1-op-at-a-time
  migration per `incremental_substrate_migration.md`.

### Neutral / follow-ups

- **ADR-0023 §4.5 amend** needs a sub-section pointing at this
  ADR-0074 (added in the same commit that lands this file).
- **`dispatch_collector.zig` (Zone 1)** retains validate / lower /
  interp axes; arm64 / x86_64 axes are removed from its `Axis`
  enum or split into a new `IRAxis` enum + Zone 2's
  `engine/codegen/dispatch_collector.zig` with its own
  `ArchAxis` enum.
- **`src/instruction/wasm_1_0/i32_add.zig`** (the B1 reference
  template) needs to drop `emit_arm64_i32_add` /
  `emit_x86_64_i32_add` from its `handlers` aggregate. The new
  arm64 / x86_64 per-op files at Zone 2 do not yet exist (they
  land in B10+).
- **`.dev/dispatcher_wire_design.md` §2.3** ("arm64 + x86_64 emit
  — cleanest wire targets — both already key on ZirOp via switch")
  is unaffected at the wire-shape level; the dispatcher target
  for those axes is the new Zone 2 collector, but the
  call-from-emit.zig pattern is identical.
- **`zone_check.sh`** needs no change; it already enforces the
  direction this ADR preserves. A new test could verify Zone 1
  per-op files do NOT import Zone 2 codegen ctx types, but the
  existing zone check already catches that.

## References

- ADR-0023 §4.5 amend (per-op file migration plan; this ADR
  supplements it).
- ADR-0073 (build-option DCE substrate; comptime resolution is
  load-bearing).
- ADR-0071 §Q3 (Hypothesis C adoption rationale).
- ROADMAP §4 (architecture / Zone).
- `.claude/rules/zone_deps.md` (zone-direction rules).
- `.dev/dispatcher_wire_design.md` (current dispatcher wire shape).
- §9.12-B / B1..B8 chunk commits (`bb85b918` through `bc7cde3d`;
  established the stub framework that surfaced this conflict).

<!--
## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-19 | `5b42f526` | Initial accepted version (B9).          |
-->
