# 0113 — callsite_metadata generalisation + regalloc 3-axis (terminator / N-successor / stack-map)

- **Status**: Accepted (2026-05-25; Phase 10 / 10.D ADR round close)
- **Date**: 2026-05-25
- **Author**: claude (autonomous loop, /continue prep path)
- **Tags**: callsite_metadata, regalloc, exception-handling, gc,
  tail-call, bounds_fixups, refactor, Phase 10 / 10.E + 10.G + 10.TC
- **Paired ROADMAP rows**: §10 / 10.E (EH impl) + §10 / 10.TC
  (Tail Call impl) + §10 / 10.G (GC impl); §10 / 10.D (this ADR's
  Accept gate)
- **Co-landed with**: ADR-0111 + ADR-0112 + ADR-0114..0117

## Context

Phase 10's three concurrent proposal implementations (Tail Call,
Exception Handling, WasmGC) each independently extend the
regalloc data shape. Without an upfront design that names the
common axes, three back-to-back patches drift toward three
incompatible regalloc shapes — exactly the W54-class failure
mode that motivated ROADMAP §P13 ("type up-front, slots over
flags") and §14's `single_slot_dual_meaning` rule.

The three axes:

1. **terminator-class** — does this op end the current basic
   block, with no fallthrough? `return_call` / `return_call_indirect`
   / `return_call_ref` set this. Liveness analysis uses it to
   stop range extension at the terminator.

2. **N-successor (callsite edges)** — does this op have more than
   one possible control-flow successor? Exception handling adds
   `try_table` entries → callsite edges target either the normal
   return PC or a landing pad. The existing `bounds_fixups.zig`
   (Phase 7) is conceptually a 1-edge specialisation of this:
   "normal fall-through OR trap-to-stub at PC `X`".

3. **stack-map (GC root carry)** — does this op require live
   reference roots to be enumerable at safepoints? `call` /
   `call_indirect` / `call_ref` need a per-callsite stack-map so
   the GC's root walker can find live refs in the caller frame.
   Per-Instance side-table (lazy compile of stack-map metadata
   alongside JIT emit).

Industry precedent — `wasmtime`'s `cranelift/codegen/src/machinst/`
+ `cranelift/frontend/src/ssa.rs` carry all three axes in
distinct fields on `ValueRegConstraint` + per-`Inst` flags. The
three are independent: a tail-call (terminator=true) has no
successors (N-successor irrelevant) and no stack-map (no GC
roots survive across the jump). A `call_ref` (regular call;
terminator=false) has 1 successor + stack-map. A `try_table`
(non-terminator) has 2+ successors + stack-map (GC roots survive
into the landing pad too).

If these axes are introduced ad-hoc in three different commits
(EH PR adds N-successor; GC PR adds stack-map; Tail Call PR
adds terminator), the three Hand-offs accumulate implicit
coupling and the regalloc.zig API surface drifts. ADR-0113
forces all three axes to be designed up-front, even though
only one of EH/GC/TC may need it per-cycle.

## Decision

Design all three axes as **orthogonal extensions to
`engine/codegen/shared/regalloc.zig`'s op-classification table**,
landing the generalisation as a single load-bearing refactor in
the first of EH/GC/TC to ship (whichever the user picks at
10.D's review). The other two consume the shape unchanged.

Six decisions codified:

1. **New shared module `engine/codegen/shared/callsite_metadata.zig`**:

   ```zig
   pub const CallsiteEdge = struct {
       kind: enum { normal_return, trap_to_stub, exception_landing_pad },
       target_pc: u32,
       live_ins: []const RegSlot,
   };

   pub const Callsite = struct {
       pc: u32,
       edges: []const CallsiteEdge,
   };
   ```

   This generalises the existing 1-edge bounds_fixups shape to N
   edges. The existing `engine/codegen/shared/bounds_fixups.zig`
   API stays unchanged but its INTERNAL data structure becomes
   a `Callsite { edges: [1] = .{ .kind = .trap_to_stub, ... }}`.
   No caller-side breakage; behaviour-preserving refactor.

2. **`exception_table.zig` is a new 2-edge specialisation** —
   each `try_table` entry produces a `Callsite { edges: [2] = .{
   { .kind = .normal_return, ... }, { .kind = .exception_landing_pad,
   ... } } }`. Shares the same backing storage as bounds_fixups
   (per-Instance arena slab).

3. **`regalloc.zig` op-classification table grows three boolean
   axes**:
   - `is_terminator: bool` (ADR-0112 / Tail Call)
   - `n_successor_edges: u8` (ADR-0114 / EH; default 1)
   - `is_safepoint: bool` (ADR-0115/0116 / GC; default false)

   Each per-op file (under `src/engine/codegen/<arch>/`) declares
   the three constants. The three are independent — combinations
   like `{terminator=true, n_edges=0, safepoint=false}` (tail-call),
   `{terminator=false, n_edges=2, safepoint=true}` (try_table over
   GC-typed call), and `{terminator=false, n_edges=1, safepoint=true}`
   (regular call) are all expressible.

4. **GC stack-map storage**: per-Instance side-table indexed by
   callsite PC. The map structure is `HashMap(u32 pc, []const
   RegSlot live_refs)`. Lazy populate alongside JIT emit (codegen
   pass walks regalloc output + emits the map for each
   `is_safepoint=true` op). Side-table NOT inlined in
   instruction stream → keeps `emit_test_*.zig` byte-identical
   for non-safepoint ops.

5. **Three-axis comptime invariants** (per
   `comment_as_invariant.md`):
   - `comptime { assert(@import("op_<tail>.zig").is_terminator); }`
     for terminator ops.
   - `comptime { assert(@import("op_<try_table>.zig").n_successor_edges >= 2); }`
     for multi-edge ops.
   - `comptime { assert(@import("op_<call>.zig").is_safepoint); }`
     for safepoint ops.

   These assertions live in `engine/codegen/<arch>/emit.zig`'s
   dispatch table population — comptime catches a per-op file
   forgetting its axis declaration.

6. **bounds_fixups refactor migration order**: land the
   refactor (`bounds_fixups → CallsiteEdge[1]`) as the FIRST
   commit of whichever proposal ships first (EH most likely,
   per design plan §3.4). Subsequent proposals consume the
   refactored shape unchanged. This avoids three independent
   refactors of the same module.

## Alternatives considered

- **A. Three independent axis introductions (per proposal PR)**.
  Rejected: the W54-class drift this ADR exists to prevent. Per
  the `single_slot_dual_meaning` rule and §P13 ("type up-front"),
  ad-hoc axis addition is forbidden when the orthogonality is
  known at design time.

- **B. Skip the generalisation; keep bounds_fixups separate from
  exception_table from gc_stack_map**. Rejected: same data
  shape (callsite PC → list of edges → list of live-in regs)
  is being reinvented three times. The refactor cost is bounded
  (~100 LOC); the carry-forward divergence cost is unbounded.

- **C. Inline stack-map into instruction stream (vs side-table)**.
  Rejected: violates `emit_test_*.zig` byte-identical invariant.
  Modern collectors (Hotspot, V8) all use side-table; only
  legacy collectors (Lua GC, MicroPython GC) inline metadata.

- **D. Push terminator/safepoint axes into ZirOp tag (per-tag
  attribute lookup)**. Rejected: ZirOp catalog is closed
  (zir_ops.zig per ADR-0087); adding per-tag attributes
  requires a sidecar table. Per-op file constant is cleaner
  + works with the existing comptime DCE substrate.

## Consequences

**Positive**:

- Three Phase 10 proposals (EH/TC/GC) consume the same regalloc
  shape — no per-proposal regalloc drift.
- bounds_fixups refactor pays the unification cost once; no
  three-way duplication.
- comptime axis assertions catch a per-op file forgetting its
  declaration at build time (mechanical safety net).
- `callsite_metadata.zig` is the single point of truth for
  callsite shape — future proposals (e.g. async/await) plug
  into the same shape.

**Negative**:

- `engine/codegen/shared/regalloc.zig` grows by ~50-100 LOC for
  the three-axis classification table. Bounded.
- Per-op files gain three constant declarations (most
  default-valued: `is_terminator: bool = false; n_successor_edges:
  u8 = 1; is_safepoint: bool = false;`). Mechanical addition;
  one-time cost.
- `bounds_fixups.zig` refactor commit needs careful audit
  (1-edge → N-edge specialisation must preserve every existing
  caller). Behaviour-preserving change, but cross-cutting.
- Per-Instance stack-map side-table adds memory per JIT'd
  function. Acceptable per design plan §3.5 (GC's per-Instance
  arena already exists).

## Removal condition

This ADR retires when:
- bounds_fixups refactored to `CallsiteEdge[1]` (behaviour-preserving)
- `exception_table.zig` lands as 2-edge specialisation (consumed by ADR-0114)
- `regalloc.zig` op-classification table carries all three axes
- All three axes have ≥ 1 consumer op-file with the const declared
- ROADMAP §10 / 10.TC + 10.E + 10.G all `[x]` (the three proposals
  consumed the shape)

At that point status transitions to `Closed (Implemented)` with
the impl SHA range cited.

## References

- `phase10_design_plan_ja.md` §3.4 — full design spec (source of
  truth; this ADR codifies the decisions).
- `~/Documents/OSS/wasmtime/cranelift/codegen/src/machinst/` —
  industry precedent for three-axis classification (per-Inst
  flags carry terminator / N-successor / stack-map).
- `~/Documents/OSS/wasmtime/cranelift/frontend/src/ssa.rs` —
  SSA construction respects the three axes during phi
  placement.
- `~/Documents/OSS/regalloc2/src/ssa.rs:103-123` — regalloc2's
  terminator classification uses TWO booleans (`f.is_branch` +
  `f.is_ret`) rather than zwasm v2's unified `is_terminator`.
  Both produce the same "stop range extension at the terminator"
  effect for the regalloc layer; zwasm v2's unification trades
  fine-grained branch-vs-ret discrimination for a single-bit
  axis per the §P13 "type up-front, slots over flags" principle.
  regalloc2 has no `safepoint` axis at the SSA layer — that
  metadata lives in the host (cranelift's VCode); ADR-0113's
  `is_safepoint` axis matches the placement (codegen layer,
  not regalloc2 itself).
- ADR-0018 — regalloc reserved set (this ADR is additive; no
  reservation change).
- ADR-0087 — ZirOp catalog (closed enum; per-op-file constants
  are the right place for axis declarations).
- ADR-0072 — `comment_as_invariant` (comptime axis assertions
  follow this pattern).
- ADR-0112 — Tail Call (consumes terminator axis).
- ADR-0114 — EH (consumes N-successor axis; co-designed).
- ADR-0115/0116 — GC (consume stack-map axis; co-designed).
- ROADMAP §P13 — "type up-front, slots over flags" (the design
  principle this ADR embodies).

## Revision history

- 2026-05-25 — Initial draft via /continue autonomous prep path
  (per `.claude/skills/continue/SKILL.md` §"Autonomous prep
  paths for user-gated ADRs"). Status: Proposed pending user
  collab review at 10.D. Co-drafted with ADR-0111 / 0112 /
  0114..0117 across the 7-ADR 10.D round.
- 2026-05-25 — Status: Proposed → **Accepted** (user collab 2/7;
  foundation ADR, accepted first per dependency order). All 6
  decisions accepted as drafted. This is the load-bearing
  foundation: bounds_fixups refactor (1-edge → CallsiteEdge[1])
  lands in the FIRST of EH/TC/GC impl rows to ship; subsequent
  rows consume the shape unchanged.
- 2026-05-26 — References §: cited regalloc2's
  `f.is_branch + f.is_ret` two-boolean terminator classification
  (`~/Documents/OSS/regalloc2/src/ssa.rs:103-123`), and noted
  regalloc2 has no safepoint axis at the SSA layer (lives in the
  host's codegen). zwasm v2's unified `is_terminator` is a
  deliberate §P13 simplification vs regalloc2's two-bool shape;
  `is_safepoint` placement at the codegen layer aligns with
  cranelift's VCode model. Documented to avoid re-walking the
  regalloc2 precedent question in future cycles.
