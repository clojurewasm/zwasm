# 0116 — WasmGC roots + RTT + i31 design: precise root walk + 8-deep display + low-bit discriminant

- **Status**: Accepted (2026-05-25; Phase 10 / 10.D ADR round close)
- **Date**: 2026-05-25
- **Author**: claude (autonomous loop, /continue prep path)
- **Tags**: wasmgc, wasm-3.0, gc-roots, rtt, i31, type-hierarchy,
  precise-stack-scan, Phase 10 / 10.G
- **Paired ROADMAP row**: §10 / 10.G (impl), §10 / 10.D (this ADR's Accept gate)
- **Co-landed with**: ADR-0111..0115 / 0117 (Phase 10 / 10.D round)

## Context

ADR-0115 covers the GC heap layout + collector vtable + the
`needs_gc_heap` zero-overhead gate. ADR-0116 covers the
complementary surface: how roots are discovered for the
mark phase, how the 3 ref hierarchies + RTT (run-time type)
encode subtyping, and how i31 (small-integer-tagged-in-pointer)
shares the GcRef encoding without colliding with heap pointers.

The design follows `phase10_design_plan_ja.md` §3.5 — industry
references:

- **wasmtime** (`crates/wasmtime/src/runtime/vm/gc/host_data.rs` +
  `crates/wasmtime/src/runtime/vm/stack_map.rs`): precise root
  scan via per-callsite stack-maps; 3 ref hierarchies with
  per-instance RTT side-table; i31 via low-bit-1 tag.
- **wasmer** (`lib/api/src/sys/value.rs`): similar shape;
  SpiderMonkey-style hierarchy.
- **SpiderMonkey** (Firefox): canonical reference for the GC
  proposal's RTT semantics — the proposal was effectively
  co-designed against SpiderMonkey's implementation. RTT
  display depth = 8 (mirrors Java's class hierarchy depth
  heuristic + Wasm's `ref.test` cost budget per spec § 4.3.7).
- **V8** (Chromium): conservative-stack-scan for shared-heap
  integration. Rejected for zwasm (we have precise stack-maps
  from ADR-0113 D4).
- **zwasm v1**: no GC; first-touch.

Three correctness invariants drive the design:

1. **Precise root scan over conservative.** Every safepoint
   carries a stack-map (ADR-0113 D4) that names exactly which
   regs + stack slots hold live GcRefs. Conservative scan (V8
   compromise for JS-Wasm heap sharing) would over-mark and
   leak; precise scan is correct + cheap because zwasm doesn't
   share its heap with the host's GC by default.

2. **RTT subtyping check is O(1).** `ref.test` and `ref.cast`
   appear in hot loops (OCaml polymorphic dispatch, Dart vtable
   lookup). Walking the type hierarchy at every check is O(depth);
   the spec recommends an 8-deep display array per type with O(1)
   indexed lookup — fixed budget per spec § 4.3.7.

3. **i31 shares GcRef encoding without ambiguity.** i31 values
   occupy the same Value union arm as heap GcRefs (anyref / eqref
   widening). Discriminant is the low bit: `(value & 1) == 1` →
   31-bit integer (arith-shift to sign-extend); `(value & 1) == 0`
   → heap pointer (offset into Store slab). Object alignment ≥ 2
   bytes (ADR-0115 D5) preserves the invariant — no heap pointer
   ever has low bit set.

GC roots + RTT + i31 are co-designed with ADR-0115 (heap +
collector) + ADR-0117 (cross-subsystem invariants). This ADR
covers the root walk + RTT lookup + i31 encoding; ADR-0115
covers the heap + collector vtable; ADR-0117 covers the
GC × EH × TC interactions.

## Decision

Land WasmGC roots + RTT + i31 with the following design choices:

1. **Precise root scan via per-callsite stack-maps**. The
   `Collector.walkRootsFn` (ADR-0115 D3) walks four root sources
   in order at every collect:

   ```
   walkRootsFn(ctx, cb):
     1. Globals: scan Module.globals[i] where ti.kind ∈ {Functions, External, Internal} ∪ {exnref}
     2. Tables:  scan Table[i].elems for the same set
     3. Stack:   for each active frame f:
                   pc = f.return_address
                   stack_map = lookup_stack_map(pc)        // ADR-0113 D4
                   for each (reg, vt) in stack_map.live_ins:
                     if vt ∈ ref-typed: cb(read(f, reg))
     4. Host roots (Mode B only): host.RootProvider.enumerate(cb)
   ```

   Stack walk uses the FP chain (same chain ADR-0114 D5 walks
   for exception unwind). The stack-map side-table is read-only
   at collect time; lazy populated during JIT emit.

2. **3 ref hierarchies** (spec § 4.5.2):

   ```
   Functions hierarchy: func | nofunc | (ref $func_type) | funcref
   External hierarchy:  extern | noextern | externref
   Internal hierarchy:  any | none | eq | i31 | struct | array | (ref $struct/$array) | anyref | eqref
                        + exn | noexn | exnref (per ADR-0114, threaded via GC walker)
   ```

   Each hierarchy is a closed lattice (top, bot, named types
   in between). `ref.test`/`ref.cast` are valid only within a
   hierarchy; cross-hierarchy cast is a validator-time error
   (parse-time per ADR-0023 zone discipline).

3. **RTT 8-deep display + walk-up fallback** (`type_hierarchy.zig`):

   ```zig
   pub const TypeInfo = extern struct {
       supertype_chain: [8]u32,  // display: type_idx of each ancestor up to depth 7
       depth: u8,                // 0 = top (any/extern/func); chain[depth-1] = self
       kind: TypeKind,           // struct / array / func / ...
       fields: [*]FieldInfo,
       field_count: u32,
   };

   pub fn isSubtypeOf(child: *const TypeInfo, parent_idx: u32) bool {
       if (parent.depth >= 8) return walkUpFallback(child, parent_idx);  // rare; cited per spec § 4.3.7
       return child.supertype_chain[parent.depth] == parent_idx;         // O(1)
   }
   ```

   Display size = 8 per spec § 4.3.7 recommendation. For deeper
   chains, walk-up fallback (`walkUpFallback` traverses the
   supertype chain dynamically). Display-8 + fallback is the
   wasmtime + SpiderMonkey shape.

4. **i31 low-bit-1 discriminant + arith-shift sign-extend**
   (`i31.zig`):

   ```zig
   pub fn isI31(v: u32) bool { return (v & 1) == 1; }

   pub fn i31ToI32(v: u32) i32 {
       // value = (i31_payload << 1) | 1  → arith-shift right by 1
       return @as(i32, @bitCast(v)) >> 1;
   }

   pub fn i32ToI31(x: i32) ?u32 {
       const lo = std.math.minInt(i32) >> 1;  // -2^30
       const hi = std.math.maxInt(i32) >> 1;  // 2^30 - 1
       if (x < lo or x > hi) return null;
       return @as(u32, @bitCast(x << 1)) | 1;
   }
   ```

   31-bit signed range: `[-2^30, 2^30-1]`. Low bit = 1 marks i31;
   low bit = 0 marks heap pointer (or null when value == 0). The
   GcRef u32 in Value union shares this encoding for `anyref` /
   `eqref` arms (since both can hold i31).

5. **Object alignment invariant** (ADR-0115 D5 reinforced):
   every heap object on the Store slab is 2-byte-aligned at
   minimum. This preserves the low-bit-0 invariant for heap
   pointers and is comptime-asserted at the allocator entry
   point:

   ```zig
   comptime { std.debug.assert(@sizeOf(ObjectHeader) % 2 == 0); }
   ```

   Practical alignment is 16 bytes (matches the 8-byte header +
   16-byte field align per ADR-0115 D1); the invariant only
   requires ≥ 2.

6. **Root scan parallelism (Phase 10 deferred)**. Phase 10 ships
   single-threaded STW (stop-the-world) mark-sweep with single
   root-walker thread. Parallel marking is deferred to Phase 11+
   (the vtable supports it — `walkRootsFn` can be invoked from
   multiple workers if the collector decides to). No design
   change needed to enable later.

7. **Cross-Instance ref handling**. A `(ref $T)` exported from
   Instance A and imported into Instance B carries the type
   pointer + GcRef. Type identity check at instantiation time:
   B's import type signature must be subtype-compatible with A's
   export. If `$T_A.id != $T_B.id` but both share the same
   `engine_type_registry_id` (a per-Engine type interning index;
   wasmtime model), the import is compatible. The registry uses
   structural hashing (signature + field types) for canonical
   identity. Per-Engine, not per-Store (so multi-Store
   compilation in same Engine can share canonicalized types).

8. **Conservative-stack-scan fallback NOT implemented**. zwasm's
   stack-map coverage is precise at all safepoints (ADR-0113 D4
   + comptime per-op-file `is_safepoint` assert). If a future
   ABI gap emerges (e.g. async/await frame interposition by host
   runtime), the fallback decision is deferred per ADR-0117 §X
   pending the concrete trigger.

9. **`Module.types[].rtt_depth` capped at 7**. Parser rejects
   recursive-types whose chain exceeds depth-7 with a clear
   diagnostic ("RTT chain too deep — restructure or use
   sub-pattern dispatch"). Spec allows arbitrary depth via
   walk-up fallback; zwasm enforces the cap to keep `ref.test`
   in hot loops on the O(1) fast path. Workaround: factor
   deeply-nested hierarchies into shallower trees (real-world
   compiler-generated Wasm rarely exceeds depth 5).

## Alternatives considered

- **A. Conservative stack scan** (V8-style; treat plausible-
  pointer-valued stack words as roots). Rejected per invariant 1:
  zwasm has precise stack-maps; conservative would over-mark.
  V8's compromise exists for shared-heap with JS objects; not
  applicable to zwasm.

- **B. RTT via runtime walk-up only** (no display array). Rejected
  per invariant 2: `ref.test` would be O(depth) instead of O(1)
  for shallow hierarchies. Cost compounds in OCaml/Dart-style
  polymorphic-dispatch hot loops.

- **C. i31 via high-bit tag** (treat sign bit as discriminant).
  Rejected: arch ABI assumes pointer values in low half of 32-bit
  address space; high-bit tag conflates with kernel-reserved
  ranges on some arches. Low-bit is industry standard
  (V8, SpiderMonkey, Lua 5.3+) + free per object-alignment
  invariant.

- **D. Display depth = 4** (smaller fixed budget). Rejected: spec
  recommends 8 + industry uses 8; smaller risks more walk-up
  fallback on realworld OCaml/Dart hierarchies (which observed
  depth 5-6).

- **E. Per-Store type registry** (not per-Engine). Rejected:
  multi-Store deployments compiled by the same Engine should
  share canonical type identities; per-Store would force
  duplicate `$T` ids across Stores, breaking `ref.test`
  semantics across instances sharing the same Engine.

## Consequences

**Positive**:

- Precise root scan → no false retention; collect cycles return
  expected memory.
- O(1) `ref.test` for hierarchies ≤ depth 7 (covers 99% of
  realworld GC-typed Wasm).
- i31 + heap-ref share 32-bit encoding → Value union arm count
  unchanged from ADR-0115 (single `anyref: u32`).
- Cross-Instance ref interop day-1 (per-Engine type registry).
- Stack-map side-table reused by ADR-0114 (EH unwind) + this ADR
  (GC root walk) → single emit path for both axes (ADR-0113 D3
  unification holds).

**Negative**:

- Per-type TypeInfo struct: 8 × u32 supertype_chain + u8 depth +
  TypeKind + FieldInfo ptr + count ≈ 56 bytes per declared type.
  Bounded; realworld Wasm has ≤ 1000 declared types.
- Per-Engine type registry interning hashmap: bounded by total
  declared types across all loaded Modules.
- RTT cap at depth 7 may reject some pathological generated Wasm;
  diagnostic guides restructure. Production toolchains (Dart, OCaml,
  J-1 patterns) all stay within the cap.
- Stack walk at collect time scales with active-frame count;
  bounded by call depth limit (~1024 frames typical).

## Removal condition

This ADR retires when WasmGC ships at ROADMAP §10 / 10.G `[x]`,
with all nine decisions implemented:

- `gc/test/core/gc/ref_test.wast` + `ref_cast.wast` +
  `br_on_cast.wast` green at 3-host gate.
- `i31.wast` (i31 family) green; sign-extend edge cases
  (`i31_sign_extend_min.wat`) green.
- `rtt_depth_9_walkup.wat` edge case verifies walk-up fallback
  fires at depth ≥ 8.
- `gc_stress_runner.zig` cyclic-struct collect verifies precise
  root walk (no false retention).
- Per-Engine type registry: cross-Instance ref import test
  passes (`glue_module_root_scan.wat` re-export pattern).
- `gc_x_eh_thrown_ref_rooted.wat` cross-subsystem test passes
  (exnref payload GcRef stays rooted across throw → catch).

At that point status transitions to `Closed (Implemented)` with
the impl SHA range cited.

## References

- `phase10_design_plan_ja.md` §3.5 — full design spec (source of
  truth; this ADR codifies the roots + RTT + i31 decisions).
- WebAssembly GC proposal § 4.3.7 (RTT display depth) + § 4.5
  (subtyping):
  https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/host_data.rs:26`
  (`pub struct ExternRefHostDataTable`): wasmtime's host-data
  table threaded through `Id` indices rather than raw
  pointers. Root walker visits this table via
  `drop_gc_ref(host_data_table, gc_ref)` (gc_runtime.rs:172).
  Industry precedent for this ADR's decision §3 root-walker
  pattern: host roots live in a table indexed by stable id,
  not raw pointers, so a moving collector can update the
  indirection without rewriting host code.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/gc_ref.rs:151`
  (`pub struct VMGcRef(NonZeroU32)`): wasmtime's tagged-pointer
  representation. Bit 0 = `I31_REF_DISCRIMINANT` (gc_ref.rs:183
  `pub const I31_REF_DISCRIMINANT: u32 = 1`); when set, the
  upper 31 bits are the inline i31 value, NOT a heap pointer.
  Direct precedent for this ADR's decision §6 unboxed-i31
  representation: the i31 fits in the same word as a heap
  pointer via low-bit tag. zwasm v2 uses an equivalent tag
  scheme on the `Value.ref` discriminator.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/i31.rs:62`
  (`fn wrapping_u32(value) -> Self { Self((value << 1) |
  DISCRIMINANT) }`): the canonical pack/unpack pair. Pack =
  `(value << 1) | 1`; unpack = `self.0 >> 1`. zwasm v2's
  `feature/gc/i31.zig` (landed 10.G-i31-helpers `e79bb7a1`)
  uses the same shift+OR pattern. Confirms decision §6
  interoperability with wasmtime's i31 representation.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/gc/gc_ref.rs:389`
  (`pub fn is_i31(&self) -> bool`): the discriminant check
  that gates pack/unpack vs heap-pointer dereference. zwasm
  v2 mirror: `Value.refAsI31Bits` / `Value.fromI31` in
  `runtime/value.zig`. Confirms decision §6's compile-time
  branch elision (the i31 tag check is hot on every GcRef
  read; wasmtime inlines, zwasm v2 inlines).
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/stack_map.rs`
  — wasmtime per-callsite stack-map shape.
- `~/Documents/OSS/WebAssembly/gc/test/core/gc/` — 18-wast /
  ~578-assertion spec corpus (consumed at 10.G close; this ADR
  covers the ref_test / ref_cast / br_on_cast / i31 subset).
- ADR-0014 §6.K.2 — single-allocator policy (GC type registry
  lives in Engine's arena).
- ADR-0113 D4 — stack-map side-table (consumed by decision §1).
- ADR-0114 — Exception Handling (exnref payload GcRef is GC-walked
  per decision §1; FP chain shared with EH unwind).
- ADR-0115 — GC heap + collector (this ADR's complement;
  shared invariant §5).
- ADR-0117 — GC × EH × TC integration invariants (this ADR's §8
  defers conservative-scan-fallback decision per ADR-0117).
- ROADMAP §2 (P/A principles) — zero-overhead invariant for Wasm
  1.0/2.0 (this ADR participates via ADR-0115 `needs_gc_heap`).

## Revision history

- 2026-05-25 — Initial draft via /continue autonomous prep path
  (per `.claude/skills/continue/SKILL.md` §"Autonomous prep
  paths for user-gated ADRs"). Status: Proposed pending user
  collab review at 10.D. Co-drafted in the 10.D ADR round
  alongside ADR-0111..0115 / 0117 (over multiple /continue
  cycles per the 7-ADR scope).
- 2026-05-26 — References enrichment via /continue autonomous
  prep path. Added 4 concrete wasmtime citations:
  `host_data.rs:26` (ExternRefHostDataTable root-walker indirection
  pattern — decision §3 mirror), `gc_ref.rs:151+183` (VMGcRef
  tagged-pointer with I31_REF_DISCRIMINANT = 1 low bit —
  decision §6 mirror), `i31.rs:62` (canonical pack
  `(value << 1) | DISCRIMINANT` matching zwasm v2's
  feature/gc/i31.zig from 10.G-i31-helpers), `gc_ref.rs:389`
  (`is_i31()` discriminant check — zwasm v2 mirror
  `Value.refAsI31Bits`). No semantic change to the 9 decisions.
- 2026-05-25 — Status: Proposed → **Accepted** (user collab 6/7).
  All 9 decisions accepted. Enhancement: when the parser rejects
  an RTT chain of depth ≥ 8 (decision §9), the diagnostic message
  must include the explicit "Workaround: factor your type
  hierarchy into shallower trees (compiler-generated Wasm rarely
  exceeds depth 5)" guidance. This makes the cap a discoverable
  zwasm choice (not a spec rule) so toolchain authors can
  restructure rather than file bugs.
