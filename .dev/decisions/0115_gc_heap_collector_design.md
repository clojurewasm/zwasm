# 0115 — WasmGC heap + collector design: per-Store slab + pluggable vtable + needs_gc_heap zero-overhead gate

- **Status**: Accepted (2026-05-25; Phase 10 / 10.D ADR round close)
- **Date**: 2026-05-25
- **Author**: claude (autonomous loop, /continue prep path)
- **Tags**: wasmgc, wasm-3.0, gc-heap, collector-vtable, mark-sweep,
  zero-overhead, Phase 10 / 10.G
- **Paired ROADMAP row**: §10 / 10.G (impl), §10 / 10.D (this ADR's Accept gate)
- **Co-landed with**: ADR-0111 / 0112 / 0113 / 0114 / 0116 / 0117 (Phase 10 / 10.D round)

## Context

The Wasm 3.0 GC proposal (function-references + WasmGC) adds
managed heap objects: structs, arrays, and 3 ref hierarchies
(Functions / External / Internal). The proposal is shipped: Dart
(`dart compile wasm`), OCaml (`wasm_of_ocaml`), Hoot (Guile-on-Wasm)
target it. ROADMAP §10 calls for GC land at row 10.G with this ADR
(plus ADR-0116 + ADR-0117) Accepted at row 10.D.

The design follows `phase10_design_plan_ja.md` §3.5 — industry
references:

- **wasmtime** (`crates/wasmtime/src/runtime/vm/gc/` +
  `crates/wasmtime/src/runtime/vm/instance/allocator/pooling/gc_heap_pool.rs`):
  per-Store contiguous slab; pluggable collector (`null` for
  drc-free testing + `drc` deferred reference counting in prod).
  Stack-map metadata per-Instance. **The naming model zwasm
  follows** — `needs_gc_heap` predicate, vtable shape.
- **wasmer** (`lib/api/src/sys/gc/`): similar shape; SpiderMonkey-
  backed collector option.
- **SpiderMonkey** (Firefox's V8-equivalent): production-grade
  mark-sweep + generational; the GC proposal was effectively
  co-designed against SpiderMonkey's implementation.
- **V8** (Chromium): conservative-stack-scan + mark-compact for
  Wasm objects on the unified JS heap.
- **WAMR** (`core/iwasm/aot/gc/`): nuclear strip option via
  `-DWAMR_GC_ENABLED=0` build flag — zwasm mirrors via
  `-Dgc=false`.
- **zwasm v1**: NO existing GC — Phase 10 is first-touch.

Three correctness invariants drive the design:

1. **Zero overhead for Wasm 1.0/2.0 modules.** A module without
   GC-typed declarations or imports must allocate zero GC heap
   bytes, run zero collector init, and bear zero per-Instance
   stack-map cost. Wasm-1.0-only customers (the majority of
   current production Wasm) must not pay for the GC proposal.

2. **GC heap lives within Runtime arena.** Per ADR-0014 §6.K.2
   single-allocator policy, the GC heap MUST be a sub-region of
   the Runtime's existing arena, not a separately-allocated
   region. Collect cycles return memory to the arena's
   free-lists, not to libc.

3. **Collector is pluggable.** Two collectors ship at Phase 10:
   `null` (bump-until-OOM; test-only) + `mark_sweep` (STW;
   production ship). Build-option `-Dgc-collector={null,mark_sweep}`
   selects. Future generational / incremental collectors plug
   into the same vtable.

GC is co-designed with ADR-0113 (callsite_metadata stack-map axis)
+ ADR-0116 (roots + RTT + i31) + ADR-0117 (cross-subsystem
invariants). This ADR covers the heap + collector + zero-overhead
gate; ADR-0116 covers root walking + RTT display + i31 encoding;
ADR-0117 covers the GC × EH × TC interactions.

## Decision

Land WasmGC heap + collector with the following design choices (9
decisions per `phase10_design_plan_ja.md` §3.5):

1. **`feature/gc/` directory structure** (Zone 1 — runtime):
   ```
   heap.zig                  Per-Store contiguous slab (arena sub-region)
   object_layout.zig         struct/array header (8-byte) + 16-byte align
   type_hierarchy.zig        3 hierarchy + RTT 8-deep display (ADR-0116)
   i31.zig                   Low-bit=1 discriminant (ADR-0116)
   collector_iface.zig       Collector vtable (this ADR)
   collector_null.zig        Bump-until-OOM (Phase 10 α; test-only)
   collector_mark_sweep.zig  STW; barrier-zero (Phase 10 β; ship)
   delegation.zig            Mode A self + Mode B host-root provider
   needs_heap_detector.zig   parse-time predicate (this ADR D2)
   ```

2. **`Module.needs_gc_heap: bool` parse-time predicate** —
   computed during section walk:
   ```
   needs_gc_heap = (heap-top ∈ {any, extern, exn})
                || (any struct/array type decl)
                || (any (ref $T) signature in func/global/table)
                || (any GC type imported)
   ```
   Set as single OR'd bit during type / table / import / global /
   function / element section parse. **Decision is at parse-time,
   NOT lower-time** — a glue/re-export module declares GC types +
   holds cross-instance refs but allocates zero objects itself
   (per J-1 patterns observed in `wasm_of_ocaml` re-export glue);
   lower-time would false-negative (zero alloc ops → predicate
   false → root scan skipped → ref drops). False positives
   ("declared but never alloc", e.g. `type-subtyping.wast` 109
   type decls / 0 allocs) are acceptable — root scan correctly
   no-ops on empty heap.

3. **Collector vtable** (`collector_iface.zig`):
   ```zig
   pub const Collector = struct {
       allocObjectFn: *const fn (ctx: *anyopaque, ti: *TypeInfo) ?GcRef,
       collectFn:    *const fn (ctx: *anyopaque) void,
       walkRootsFn:  *const fn (ctx: *anyopaque, callback: RootCallback) void,
       ctx: *anyopaque,
   };
   ```
   Shape mirrors `std.mem.Allocator` — vtable pointer + opaque
   ctx + interface methods. Two implementations ship:
   - `collector_null.zig`: bump-pointer allocator over the slab;
     `collectFn` is no-op; `walkRootsFn` no-op. Test-only —
     verifies the alloc + ref-walk paths without the collect
     complexity.
   - `collector_mark_sweep.zig`: STW mark-sweep over the slab;
     barrier-zero (no write barriers). Production ship for
     Phase 10. Per `phase10_design_plan_ja.md` §3.5 (β must-ship).
   `-Dgc-collector={null,mark_sweep}` build-option selects;
   `-Dgc=false` strips the entire `feature/gc/` directory via
   compile-time DCE (WAMR-equivalent nuclear strip).

4. **Host GC delegation** — Mode A default, Mode B opt-in:
   - **Mode A (default)**: zwasm owns the GC. Host marks roots
     via `zwasm_runtime_with_root_scope(rt, callback)` —
     callback runs with collector frozen; any `GcRef` reachable
     within the callback's scope is treated as a root.
   - **Mode B (opt-in; ~50 LOC)**: host provides a
     `RootProvider` vtable; at collect-time zwasm imports the
     host's root enumeration. For GC'd host languages (the
     ClojureWasmFromScratch use case where Clojure JVM heap
     references zwasm objects).
   - **Mode C** (GC type registry public): deferred to v0.1.0 RC+
     (requires type-registry pub-leak audit).

5. **Per-Store contiguous slab backing**:
   - Slab = `[]u8` allocated via `std.heap.ArenaAllocator` over
     the Runtime arena. 4 KB page granularity for grow.
   - 32-bit indexed `GcRef` (offset into slab). 4 GiB heap cap
     per Store; multi-Store deployment for larger heaps.
   - Object alignment = 2 bytes minimum (preserves low-bit for
     i31 discriminant per ADR-0116).
   - `null = 0` sentinel (offset 0 reserved; never allocated).
   - **Per ADR-0014 §6.K.2**: GC heap is Runtime arena
     sub-region. `collect` returns swept regions to the arena's
     internal free-list; arena `deinit` (Runtime teardown)
     frees the slab. No separate libc allocator path.

6. **`Value` union extension** — add `anyref` arm:
   ```zig
   pub const Value = extern union {
       i32: i32, i64: i64, f32: f32, f64: f64,
       v128: [16]u8,
       funcref: u32,    // Phase 2 — Functions hierarchy
       externref: u32,  // Phase 2 — External hierarchy
       anyref: u32,     // Phase 10 — Internal hierarchy (new)
   };
   ```
   The 3 ref arms are parallel — same u32 (GcRef) backing, but
   distinct enum tags so the validator + runtime can enforce
   hierarchy separation. `exnref` (Exception hierarchy via
   ADR-0114) stores `?*Exception` pointer, NOT a GcRef — but is
   root-scanned by the GC walker.

   **`ValType` enum extension** (this Revision 2026-05-27
   amendment): the parser-/validator-side ValType enum
   (`ir/zir.zig::ValType`) extends with 5 new closed-enum
   variants:
   ```zig
   pub const ValType = enum(u8) {
       i32, i64, f32, f64,                  // Wasm 1.0 numeric
       v128,                                 // Wasm 2.0 SIMD
       funcref, externref,                   // Wasm 2.0 ref
       anyref, eqref, structref, arrayref,   // Wasm 3.0 GC (new)
       i31ref,                               // Wasm 3.0 GC (new)
   };
   ```
   Per Wasm 3.0 spec binary encoding: anyref 0x6E / eqref 0x6D /
   structref 0x6B / arrayref 0x6A / i31ref 0x6C. Parser /
   validator / runtime branches recognise these bytes at the
   sub-chunks following ValType-extension cycle.

   **Cascade pattern decision** — closed-enum + per-site arm
   added on demand. Rationale:
   - Closed-enum preserves Zig 0.16 exhaustiveness checking
     (per ADR-0009's `require_exhaustive_enum_switch` lint
     rule), which catches "forgot to handle a new valtype"
     bugs at compile time — load-bearing for the 217-site
     switch surface (parse / validate / lower / emit / interp
     / runtime / api crossing).
   - Non-exhaustive `enum(u8) { …, _ }` shape was considered
     and REJECTED: forces `else =>` on every switch, which
     defeats the very static checking the lint exists to
     enforce; trades a one-time mechanical cascade cost for
     permanent loss of exhaustiveness signal.
   - Per-site cascade: each ValType switch arm-out adds
     handling for the relevant new variants when the per-op
     sub-chunk lands. Sites that don't yet need GC semantics
     (e.g., numeric op handlers) add `.anyref, .eqref,
     .structref, .arrayref, .i31ref => unreachable` — the
     numeric ops don't accept ref-typed operands at the
     validator level, so the runtime arm is provably-dead.
     Sites that DO need GC semantics (e.g., the future
     `op_gc.zig` dispatcher) add real handling per-variant.
   - The ValType extension lands as a single sub-chunk
     (sub-chunk 1 per `.dev/phase10_g_op_bundle_plan.md`);
     the per-site cascade lands alongside in the same commit
     OR in immediate-follow sub-chunks (per chunk granularity
     rules in `LOOP.md`: bundle when ≤ 800 LOC src + 400 LOC
     test; split when > 1200 LOC).
   - Anti-pattern AVOIDED: extending ValType with @panic
     stubs as the default cascade arm. Per
     `platform_panic_vs_error.md` the @panic pattern targets
     `comptime`-pruned target-conditional `else` branches —
     NOT enum-extension cascades. For GC valtypes the
     correct cascade arm is `unreachable` (where the
     validator has type-system-proven the value can't reach)
     or explicit per-variant handling (where it can).

7. **Stack-map per-Instance side-table** (ADR-0113 D4) — NOT
   per-function field. Table is `HashMap(u32 callsite_pc, []const
   RegSlot live_refs)`. Lazy populate alongside JIT emit (codegen
   pass writes the map for each `is_safepoint=true` op). Stays
   out of the instruction stream → `emit_test_*.zig` byte-identical
   guarantee holds for non-safepoint ops.

8. **`engine/codegen/<arch>/op_gc.zig` new** — struct.new /
   struct.get / struct.set / array.new / array.get / array.set /
   ref.test / ref.cast / br_on_cast. **`op_i31.zig` is a sibling
   file** (i31 family is small + uses distinct discriminant
   encoding; bundling with op_gc.zig would tempt sharing helpers
   across the i31/heap-ref boundary).

9. **Allocation-during-collect reentry guard** — `collectFn` sets
   a thread-local `in_collect: bool` flag; `allocObjectFn` asserts
   `!in_collect` (debug builds) / returns `null` (release builds).
   The guard catches finaliser-style misuse + the rare
   weak-callback-during-mark recursion. wasmtime + V8 both
   implement the same guard.

## Alternatives considered

- **A. Always-on GC heap (no `needs_gc_heap` predicate)**. Rejected:
  violates zero-overhead invariant. Wasm-1.0 customers pay no GC
  cost today; landing GC must preserve that for non-GC modules.

- **B. Lower-time `needs_gc_heap` instead of parse-time**. Rejected:
  glue/re-export modules (J-1 patterns; `wasm_of_ocaml` style)
  have zero alloc ops but hold cross-instance refs → root scan
  required. Lower-time would false-negative.

- **C. Generational collector at Phase 10**. Rejected: STW
  mark-sweep is sufficient for the GC proposal's spec corpus;
  generational adds write-barrier complexity. Phase 11+ may add
  it via the same vtable.

- **D. Conservative stack-scan** (V8-style: walk Zig native stack
  + treat plausible-pointer-values as roots). Rejected: zwasm has
  precise stack-maps at every safepoint (ADR-0113 D4); precise
  scan is correct + cheaper. Conservative scan is V8's compromise
  for sharing the JS heap with non-Wasm objects.

- **E. Separate libc-backed GC heap** (bypass Runtime arena).
  Rejected: violates ADR-0014 §6.K.2. The Runtime arena is the
  single allocator; GC sub-region keeps the invariant.

- **F. Bundle i31 into op_gc.zig**. Rejected per
  single_slot_dual_meaning rule. i31's low-bit discriminant
  encoding differs structurally from heap-ref encoding; sharing
  helpers tempts conflation.

## Consequences

**Positive**:

- Wasm 3.0 `gc/test/core/gc/*.wast` (18 wast / ~578 assertion) +
  function-references deltas green at 3-host gate after impl.
- Wasm 1.0/2.0 modules see ZERO GC overhead (predicate-gated).
- Pluggable collector → future generational / incremental
  collectors plug into same vtable without API breakage.
- Per-Store slab → multi-Store deployments scale heap linearly.
- `-Dgc=false` nuclear strip → embedded/MCU targets can ship
  zwasm without the GC code entirely.
- ClojureWasmFromScratch (Mode B host delegation) — GC'd host
  language integration day-1.

**Negative**:

- New file count under `feature/gc/`: 9 files; ~1500 LOC estimate.
- `engine/codegen/<arch>/op_gc.zig` ×2 + `op_i31.zig` ×2 = 4 new
  files; ~800 LOC estimate.
- `Module.needs_gc_heap` parse-time predicate adds a field to the
  parsed Module struct (~1 byte). Bounded.
- Per-Store slab fixed cost for GC-enabled modules: 4 KB initial
  + grow. Mitigated by `needs_gc_heap=false` → 0 bytes.
- Stack-map side-table grows with safepoint count × function
  count. Per-Instance arena absorbs.
- Collector vtable adds 4×pointer (32 bytes) per Store. Bounded.

## Removal condition

This ADR retires when WasmGC heap + collector ships at ROADMAP
§10 / 10.G `[x]`, with all nine decisions implemented:

- `gc/test/core/gc/*.wast` (18 wast) green at 3-host gate.
- `function-references/test/core/*.wast` deltas green.
- `test/runners/gc_stress_runner.zig` matrix passes:
  - heap pressure (10^5 obj alloc → collect → re-alloc)
  - allocation-during-collect reentry guard
  - cyclic struct collect (mark-sweep cycle verify)
- `emit_test_gc.zig` golden snapshot stable (~10 representative
  ops: struct.new / array.set / ref.test / etc.).
- `glue_module_root_scan.wat` edge case verifies parse-time
  predicate fires on the J-1 declare-but-no-alloc pattern.
- `realworld/p10/dart/` + `realworld/p10/wasm_of_ocaml/` +
  `realworld/p10/hoot/` realworld fixtures green.
- Wasm 1.0/2.0 fixture suite regression: zero bench delta on
  non-GC modules (verified via `bench/`).

At that point status transitions to `Closed (Implemented)` with
the impl SHA range cited.

## References

- `phase10_design_plan_ja.md` §3.5 — full design spec (source of
  truth; this ADR codifies the heap + collector decisions).
- WebAssembly GC proposal:
  https://github.com/WebAssembly/gc
- WebAssembly function-references proposal (GC prereq):
  https://github.com/WebAssembly/function-references
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/` —
  per-Store slab + pluggable collector industry precedent.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/gc_runtime.rs:43`
  (`fn new_gc_heap(&self, engine) -> Result<Box<dyn GcHeap>>`):
  wasmtime's `GcRuntime` trait factory method that produces a
  fresh `dyn GcHeap` per Store. Direct precedent for this ADR's
  decision §1 (per-Runtime slab) — each store gets its own heap,
  the trait object enables collector pluggability.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/gc_runtime.rs:87`
  (`pub unsafe trait GcHeap`): the collector's vtable surface
  (`alloc_raw` / `alloc_uninit_struct_or_exn` / `alloc_uninit_array`
  / `drop_gc_ref` / `reset` / `allocated_bytes`). Mirrors this
  ADR's decision §3 pluggable vtable shape — same allocation
  primitives + the `reset` method for heap reuse across stores.
  Note: wasmtime's reset/reuse model (line 50: "may be reused
  with new stores after its original store is dropped") is more
  aggressive than zwasm v2's per-Runtime-bound model; this ADR
  diverges per ADR-0014 §6.K.2 single-allocator policy.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/enabled/drc.rs:85`
  (`pub struct DrcCollector`): wasmtime's deferred-reference-
  counted collector. Reference for the "must-ship mark_sweep
  collector + null test-only" decision §4 — wasmtime ships DRC
  as its main collector; zwasm v2 chose mark-sweep instead per
  P&A simplicity vs DRC's barrier complexity.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/enabled/null.rs`
  (`pub struct NullCollector`): wasmtime's null collector
  (bump-allocates until OOM; no GC). Direct precedent for this
  ADR's decision §4 null-collector test-only path — same
  semantic (allocate-only, never collect) for test fixtures
  that don't need reclamation.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/instance/allocator/pooling/gc_heap_pool.rs`
  — wasmtime's per-Instance heap pool.
- `~/Documents/OSS/WebAssembly/gc/test/core/gc/` — 18-wast /
  ~578-assertion spec corpus (consumed at 10.G close).
- ADR-0014 §6.K.2 — single-allocator policy (this ADR's GC slab
  is a Runtime arena sub-region per the invariant).
- ADR-0113 — callsite_metadata stack-map axis (consumed by this
  ADR's decision §7).
- ADR-0114 — Exception Handling (exnref is GC-walked but
  separately stored).
- ADR-0116 — GC roots + RTT + i31 (co-designed; this ADR covers
  heap + collector, ADR-0116 covers root walking).
- ADR-0117 — GC × EH × TC integration invariants (co-designed).
- ROADMAP §2 (P/A principles) — zero-overhead invariant for
  Wasm 1.0/2.0 modules (this ADR's decision §2 honours).

## Revision history

- 2026-05-25 — Initial draft via /continue autonomous prep path
  (per `.claude/skills/continue/SKILL.md` §"Autonomous prep
  paths for user-gated ADRs"). Status: Proposed pending user
  collab review at 10.D. Co-drafted in the 10.D ADR round
  alongside ADR-0111 / 0112 / 0113 / 0114 / 0116 / 0117 (over
  multiple /continue cycles per the 7-ADR scope).
- 2026-05-26 — References enrichment via /continue autonomous
  prep path. Added 4 concrete wasmtime citations: `gc_runtime.rs:43`
  (GcRuntime::new_gc_heap factory), `gc_runtime.rs:87` (GcHeap
  trait vtable shape + reset model divergence note),
  `enabled/drc.rs:85` (wasmtime's DrcCollector — zwasm v2 chose
  mark-sweep instead), `enabled/null.rs::NullCollector`
  (test-only null collector precedent). No semantic change to
  the 9 decisions.
- 2026-05-25 — Status: Proposed → **Accepted** (user collab 5/7).
  All 9 decisions accepted. Enhancement: `Module.needs_gc_heap`
  parse-time bit gets declared as a load-bearing field with a
  pinned offset in the parsed `Module` extern struct; ABI-freeze
  to prevent silent drift when later /JIT / Instance init paths
  consume it. Field offset + name are cited in Reference § so
  that future audits can grep its presence mechanically. Mode B
  (host root provider; ~50 LOC) ships in Phase 10 alongside
  Mode A; `-Dgc=false` nuclear strip ships as a Phase 10
  invariant (10.P close); `null` collector test-only; mark_sweep
  must-ship.
- 2026-05-27 — Decision §6 amended via /continue autonomous
  prep path (per `.dev/phase10_g_op_bundle_plan.md` sub-chunk
  1). Added `ValType` enum extension (5 new closed variants
  for anyref / eqref / structref / arrayref / i31ref) +
  cascade pattern decision (closed-enum + per-site arm-out
  per LOOP.md chunk granularity; REJECTED non-exhaustive
  `enum(u8) { …, _ }` shape because it defeats ADR-0009's
  exhaustiveness lint). Foundation-cycle work `e953b089`
  added the parallel `Value.anyref` arm; this amendment
  authorises the ValType-side counterpart for the op_gc
  bundle. Implementation lands at op_gc bundle sub-chunk 1
  (next cycle).
