# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `e3bd30e1` — feat(p10): feature/gc/heap.zig per-Store
  slab (10.G-foundation cycle 3). Bump-pointer allocator over a
  Runtime-arena-backed slab; 32-bit GcRef, 2-byte align, 4 KB
  page grow, 4 GiB cap. No collector / no root walker yet.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 18 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.G-foundation
- **Cycles-remaining**: ~3
- **Continuity-memo**: Cycle 1 (`e953b089`) Value.anyref +
  Module.needs_gc_heap field. Cycle 2 (`3fa32ddf`) parser wires
  needs_heap_detector. Cycle 3 (`e3bd30e1`) feature/gc/heap.zig
  per-Store slab + 7 tests. Next steps: (4) Collector vtable +
  null collector α (ADR-0115 §10) — `collector_null.zig` wraps
  heap.zig as the allocator-only implementation; (5) regalloc
  stack-map axis (ADR-0113 §C / ADR-0115 §7); (6) instantiate-
  side gate that materialises Heap iff Module.needs_gc_heap.
- **Exit-condition**: instantiate-side gate consumes
  Module.needs_gc_heap AND on first struct.new the Heap.allocate
  returns a non-null GcRef readable via Value.anyref.

## Spec runner observable (HEAD `e953b089`)

```
[memory64           ] return=337 (pass=337 fail=0  ) trap=205 (pass=205 fail=0  ) invalid=83  (pass=83  fail=0) skip=0
[tail-call          ] return=31  (pass=31  fail=0  ) trap=0   (pass=0   fail=0  ) invalid=10  (pass=10  fail=0)
[exception-handling ] return=34  (pass=0   fail=34 ) trap=2   (pass=0   fail=2  ) invalid=7   (pass=5   fail=2  ) exception=4 (pass=0 fail=4)
[function-references] invalid=12  (pass=12  fail=0)
total: return pass=368 fail=34; trap pass=205 fail=2; invalid pass=110 fail=2; exception pass=0 fail=4
```

memory64 / tail-call / function-references all clean. Remaining 40
fails all in exception-handling (gate per D-192 / 10.G).

Recent commits this resume:
- `e3bd30e1` feat — feature/gc/heap.zig per-Store slab (10.G cycle 3).
- `3fa32ddf` feat — parser wires needs_heap_detector (10.G cycle 2).
- `e953b089` feat — Value.anyref + Module.needs_gc_heap (10.G cycle 1).
- `94d16e33` chore — audit_scaffolding §F+§G clean; retarget at 10.G.
- `9b03db83` chore — pivot 10.E-EH-compile-runtime bundle; file D-192.

## Next sub-chunk candidates (names only)

- **10.G-foundation cycle 4** — Collector vtable + null collector
  α (ADR-0115 §10): `Collector` vtable struct (allocFn / collect
  Fn / walkRootsFn / ctx); `collector_null.zig` wraps Heap as
  alloc-only (collect + walk are no-ops). `-Dgc-collector=
  {null,mark_sweep}` build option lands at cycle 5+.
- **10.G-foundation cycle 5** — Instantiate-side gate:
  Runtime.gc_heap allocates iff Module.needs_gc_heap; otherwise
  stays null (zero-overhead invariant per ADR-0115 §1).
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl (10.G bundle scope).
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5 (GC-gated).
- D-188 — 2 now (try_table.8 + try_table.10); blocked-by 10.E
  validator strictness (GC-gated via D-192).
- D-192 — EH runtime path blocked-by exnref ValType + cross-module
  register support (GC-gated).

## Key refs

- ADR-0017, ADR-0026, ADR-0109, ADR-0111 (memory64 design),
  ADR-0112, ADR-0113 §A/§B/§C, ADR-0114, ADR-0115 (GC heap), ADR-0116
  (GC roots + RTT + i31), ADR-0117 (GC×EH×TC integration), ADR-0119,
  ADR-0120.
- ROADMAP §10 row 10.G; Phase log `.dev/phase_log/phase10.md` Row
  10.T / 10.TC / 10.E / 10.M.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
