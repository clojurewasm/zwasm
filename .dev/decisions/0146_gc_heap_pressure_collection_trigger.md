# 0146 — GC heap-pressure collection trigger (§15.1 chunk 1c)

- **Status**: Accepted (2026-06-04; autonomous per ADR-0132 / §15.1 planned work)
- **Date**: 2026-06-04
- **Author**: claude (autonomous, /continue bundle 15.1-gc-reclamation)
- **Tags**: Phase 15, GC, mark-sweep, collection trigger, rooting, D-211
- **Amends**: none (implements ROADMAP §15.1; extends ADR-0115 §10 / ADR-0135
  no-reclaim-interim with the production collection driver)

## Context

Before §15.1, `MarkSweepCollector.collect()` was **never invoked in production**:
`Heap.allocate` only bumps the cursor / grows the slab, and the collector +
`RootScope` were instantiated solely in tests (survey 2026-06-04). So GC never
ran outside the test suite — the mark-sweep machinery was dead in shipped code.

§15.1 chunk 1c adds the missing trigger: a collection must fire when the heap
crosses a pressure threshold. Two questions had to be answered:

1. **Where does the collector live in production?** The interp alloc handlers
   (`struct_ops.structNew` / `array_ops.arrayNew`) have `rt.gc_heap` AND
   `inst.gc_type_infos` (via `rt.instance`) in scope, but no collector/RootScope.
2. **Where is pressure tracked, and what drives the collection?**

## Decision

**Transient collector, driven from the interp alloc handlers; pressure
bookkeeping on the Heap.**

- `MarkSweepCollector` is effectively **stateless** (it holds `*Heap`,
  `*const GcTypeInfos`, output `last_stats`, an opaque runtime back-pointer, and
  the `scan_native_stack` flag). It is therefore constructed **on demand** at the
  trigger site, never stored — no persistent collector field on Runtime/Store.
- The driver `object_alloc.maybeCollect(heap, gti, rt, alloc)` checks
  `heap.shouldCollect()`; on pressure it builds a transient
  `MarkSweepCollector` + `RootScope`, sets `scan_native_stack = true` (a JIT
  frame may be live and hold the only reference to an in-flight object — §15.1
  chunk 1b), runs `RootScope.collect()` (walk roots → mark → sweep), then
  `heap.noteCollected()`.
- `Heap` gains the pressure signal: `pressure_bytes` (threshold, default 1 MiB,
  settable for tests), a `next_gc_at` cursor watermark, a `gc_cycles` counter
  (the production-observable proof a collection ran), `shouldCollect()`, and
  `noteCollected()` (advance the watermark + bump `gc_cycles`).
- The driver lives in `object_alloc.zig` (already imported by both handlers).
  Imports `runtime` + `root_scope` + `collector_mark_sweep` **one-way** (none of
  them import `object_alloc`), exactly as `root_scope.zig` already imports
  `runtime` — so no import cycle and no new shallow module (file_size N3).

## Rejected alternatives

- **Persistent collector field on Runtime** — would force `runtime.zig` to
  import the concrete `MarkSweepCollector`, the cycle the opaque `runtime:
  ?*anyopaque` back-pointer was introduced to avoid. Unnecessary: the collector
  is stateless and cheap to build per collection.
- **Trigger inside `Heap.allocate`** — the Heap (Zone-1 leaf) cannot reach the
  Runtime/roots, so it physically cannot drive a collection. Heap owns only the
  pressure *signal*; the handler owns the *driver*.
- **New `markRootFn` entry on the `Collector` vtable** — would re-shape the
  ADR-0115 §3 vtable just to avoid the existing `RootScope.markCallback`
  downcast. `RootScope` already encapsulates walk→mark→sweep; reuse it.

## Consequences

- **Safety**: chunk 1c does NOT reclaim (sweep still counts only — ADR-0135
  no-reclaim interim holds until chunk 2 free-list reuse). So a mis-fired or
  over-conservative trigger CANNOT cause use-after-free here; the only
  observable effect is `gc_cycles` advancing + sweep stats. Reclamation (chunk 2)
  is what couples to rooting correctness, and it is gated behind the validated
  native-stack scan (chunk 1b, `b46960db`).
- Default `pressure_bytes = 1 MiB` is a first cut; a build-option / adaptive
  growth policy is chunk-2+ polish, not load-bearing.
- `scan_native_stack = true` at the trigger means every production collection
  pays the conservative stack walk. Acceptable for β; a precise GcRootMap path
  (ADR-0128 §2 / ADR-0141) is a later optimisation, not required for non-moving.
