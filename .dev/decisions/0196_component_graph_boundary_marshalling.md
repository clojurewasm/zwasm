# ADR-0196 — Two-level component-graph linking + cross-component aggregate marshalling (D-305)

- Status: **Accepted** (autonomous; implemented + verified `4cceeb1e`). Lifts `instantiateGraph` from
  flat-u32-only to a fully-general (string-capable) component linker. Closes the D-305 first milestone
  (a STRING crosses the component boundary correctly).
- Date: 2026-06-17
- Relates: ADR-0170 (Component Model substrate), ADR-0175 (single-component build engine), D-305 (the linker
  gap), the `adder_graph` flat-func precedent. Unblocks the D-335 async chain's eventual cross-component routing.

## Context

`instantiateGraph` (Zone-3) linked a 2-component graph only when each child had exactly ONE core module and the
cross-component call passed FLAT scalars (a direct core call, no boundary marshalling — `adder_graph`). A
realistic aggregate-passing component needs a `$libc` core module (memory + `cabi_realloc`) PLUS its main
module, and the string param must be COPIED from the caller's linear memory into the callee's, since each
component owns its own memory. The flat path mis-handled both (the RED fixture `strlen_graph` returned
`ExportNotResolved` because `firstCoreModule` instantiated only `$libc`).

## Decision

New Zone-3 module `src/api/component_graph.zig` (extracted from `component.zig`) does **two-level
instantiation**:

1. **Outer**: walk the composed component's `component_instances` in order; each child is a full component.
2. **Inner (per child)**: walk that child's `core_instances` with `with`-arg resolution — the same shape as
   `buildWasiP2Component`'s core-instance loop (`component_wasi_p2.zig:2112`), but the child's component-level
   imports are satisfied from the OUTER `with` args (pointing at an earlier child's lifted export) instead of
   WASI host ops. `GraphChild` tracks each child's `cabi_realloc` + memory-exporting core instances.
3. **Boundary marshalling**: a child's `canon lower` of a cross-component import becomes a host trampoline
   bound to a `BoundaryCtx` (callee child + its lifted core func + the imported func type). On call it uses
   `canon.CanonContext` (memory_fn + realloc_fn wired to the CALLEE child) to lift each arg into the callee's
   own memory — a `string` arg is copied caller-mem → callee-mem via the callee's `cabi_realloc`, never passed
   through as a raw foreign `(ptr,len)` — then invokes the provider's core func and lowers the result back.

A boundary arg/result shape the marshaller does not yet implement returns a **typed
`error.UnsupportedBoundaryType`** (a loud deferral, never a silent mis-marshal — `no_workaround.md`).

## Alternatives rejected

- **Pass `(ptr,len)` through unchanged** (the old flat shortcut) — wrong for aggregates: the callee reads ITS
  memory at the caller's offset → garbage/trap. The `strlen_graph` fixture (`firstbyte` READS the bytes) pins
  this.
- **A bespoke per-type marshaller in the graph linker** — rejected; reuse `canon.CanonContext`, the same
  lift/lower machinery the WASI host boundary uses, so component↔component and host↔component share one path.

## Consequences

- `instantiateGraph` is now string-capable; `component_model_assert` 159/0/0 (`strlen` PASS + `adder` flat
  regression intact). Verified build + test + test-spec + test-component-spec + lint green.
- D-305 first milestone closed. **Remaining (continued D-305)**: other aggregate shapes (list / record / result
  / tuple) across the boundary, result-direction string marshalling, and >2-component / deeper graphs — they
  reuse `BoundaryCtx`/`CanonContext` but are untested; each lands when a fixture demands it (or extend the
  `strlen` corpus). The async cross-component routing (ADR-0195 scheduler prerequisite) is a further axis.
