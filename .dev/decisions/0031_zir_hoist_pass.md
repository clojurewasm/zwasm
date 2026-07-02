# 0031 — ZIR-stage hoist pass (constant hoisting MVP)

- **Status**: Closed (Phase 8 DONE)
- **Date**: 2026-05-08
- **Author**: Phase 8 / §9.8 / 8.4 autonomous /continue cycle
- **Tags**: roadmap, phase8, jit, optimisation, zir, hoist, licm

## Context

Phase 8 (per ADR-0019 scope shift) is the JIT optimisation
foundation. The first optimisation row is §9.8 / 8.4 — hoist
pass — slated for v1's W43-class loop-invariant code motion
ported onto v2's ZIR substrate.

The §9.8 / 8.4 entry survey (private/notes/p8-8.4-survey.md;
re-derivable) confirmed:

- `src/ir/analysis/loop_info.zig` is **already implemented**
  (Phase 5.3 reservation discharged at lower-time): `compute()`
  walks `ZirFunc.blocks` for `kind == .loop` frames and emits
  parallel `[]u32` slices `loop_headers` + `loop_end`.
- `ZirFunc.loop_info: ?LoopInfo = null` slot is reserved in
  `src/ir/zir.zig:548`.
- `ZirFunc.hoisted_constants: ?[]HoistedConst = null` slot is
  reserved at line 568, with the `HoistedConst` struct shape
  pre-defined.
- Liveness analysis (`src/ir/analysis/liveness.zig:compute`) is
  in the pipeline at `src/engine/codegen/shared/compile.zig:95`
  before regalloc.
- v1's W43 attempt ran **post-regalloc** and broke x86 due to
  `inst_ptr` cache slot collision (W54-postmortem). v2's day-1
  `?Liveness` slot per ROADMAP §P13 is reserved precisely so
  hoist can run **pre-regalloc** without W54-class fragility.

Cranelift's LICM (loop_analysis.rs) uses dominator-tree CFG
analysis. Wasm's structured control flow (spec §3.5.1 forbids
irreducible loops) makes the heavier dominator-tree machinery
unnecessary for v2 — the ZIR `loop / end` opcodes give
syntactic loop scope directly.

## Decision

**Land a minimal hoist pass at `src/ir/hoist/pass.zig` that
hoists loop-invariant `i32.const` / `i64.const` / `f32.const` /
`f64.const` instructions from inside `loop` frames to a
synthetic preheader region immediately preceding the loop
header.** Pipeline placement: between `lower` and `liveness`
in the JIT compile path
(`src/engine/codegen/shared/compile.zig`):

```
lower → loop_info.compute → hoist.pass → liveness.compute → regalloc → emit
```

Concrete shape:

1. **Module**: `src/ir/hoist/pass.zig` exports
   `pub fn run(allocator: Allocator, func: *ZirFunc) Error!void`.
   It mutates `func.instrs` in place + writes
   `func.hoisted_constants` for downstream observability.
2. **Loop detection**: reuses `loop_info.compute()`'s output
   (caller installs `func.loop_info` first, OR the hoist pass
   computes it on-demand and frees before returning).
3. **Invariance check (MVP)**: for each `*.const` instruction
   inside a loop body (`loop_headers[i] < pc < loop_end[i]`),
   the instruction is by definition loop-invariant (constants
   never change). No vreg-write-pattern analysis is needed for
   the MVP — constants are the trivial invariant case.
4. **Splice mechanics**: hoisted constants prepend to `func.
   instrs` immediately before each `loop_headers[i]` PC. Existing
   `func.blocks[]` start_inst / end_inst entries shift forward
   by the count of constants hoisted into that loop. Branch
   targets in `func.branch_targets[]` shift identically. The
   pass updates all three arrays in lockstep.
5. **Hoisted-constant record**: each successful hoist adds an
   entry to `func.hoisted_constants` of shape `{
   original_pc: u32, new_pc: u32, op: ZirOp, payload: u64 }`.
   Phase 15+ work can read this for further optimisation
   (constant-pool pooling, dead-store elimination feedback).
6. **Boundary cases**:
   - Constants used both inside and outside the loop: still
     hoistable (the hoisted instr writes the same vreg; uses
     downstream are unaffected because the vreg's value is
     unchanged).
   - Nested loops: hoist to the **outermost** loop containing
     the constant. This is the maximum-benefit placement and
     avoids the per-iteration cost of inner loops.
   - Multiple identical constants: each gets its own hoisted
     entry in this MVP. Pooling (one hoisted instr serves
     multiple original constants with identical payload) is
     deferred to Phase 15.

## Alternatives considered

### Alternative A — Full LICM (load + arithmetic + global.get)

- **Sketch**: Hoist all loop-invariant operations, including
  loads, arithmetic on loop-invariant operands, and `global.get`.
- **Why rejected for MVP**: Each new hoist class brings its own
  invariance-checking complexity (alias analysis for loads;
  vreg-write-pattern dataflow for arithmetic; alias for
  globals). MVP starts with constants — the trivial case where
  invariance is by definition. Subsequent passes can extend the
  invariant detector. Rejecting "land everything at once" per
  ROADMAP §P14 ("simplest correct implementation").

### Alternative B — Post-regalloc hoist (mirror v1 W43)

- **Sketch**: Run hoist after regalloc; cache hoisted vregs in
  callee-saved registers reserved at prologue.
- **Why rejected**: W54-postmortem documents this approach's
  fragility — `inst_ptr` cache competition broke x86. v2's
  day-1 `?Liveness` slot exists exactly to make pre-regalloc
  hoist viable without that competition. Per ROADMAP §P13.

### Alternative C — Cranelift dominator-tree LICM

- **Sketch**: Build CFG + dominator tree from ZIR, run cranelift-
  style LICM with full SSA-style invariance dataflow.
- **Why rejected**: Wasm spec §3.5.1 forbids irreducible loops —
  the structured `loop / end` opcodes give syntactic scope
  directly. Dominator tree adds ~500 LOC of machinery for zero
  algorithmic benefit on Wasm guests. ZIR's linear-scan label-
  stack loop detection (already in `loop_info.zig`) is
  sufficient.

### Alternative D — Defer hoist to Phase 15 entirely

- **Sketch**: Phase 8 = regalloc upgrade only; Phase 15 = full
  v1-class optimisation port.
- **Why rejected**: ADR-0019 scope shift placed optimisation
  foundation at Phase 8 explicitly. Constant hoist is the
  **simplest** hoist class — a clean MVP unblocks the bench-
  delta target (8.8: ≥10% improvement on 3+ fixtures vs Phase
  7 close baseline). Deferring everything until Phase 15
  forfeits the bench-delta gate.

## Consequences

### Positive

- **First JIT optimisation lands cleanly.** ZIR substrate's
  day-1 slots make this a structural addition, not a retrofit.
- **No regression risk to per-arch backends.** Pre-regalloc
  hoist creates new vregs in the same scope as constant
  emission; regalloc + emit see no shape they didn't already
  handle. Three-way differential gate (P12) verifies.
- **Bench delta candidate.** Tight loops with constant-divisor
  arithmetic (`fib2`, `tinygo/tak`, magic-divide hot paths)
  benefit immediately. ≥10% improvement target on 3+ fixtures
  (§9.8 / 8.8) is more reachable.
- **Pipeline foundation for further hoist classes.** 8.5 (coal-
  escer) and 8.6 (regalloc upgrade) build on the same `?Liveness`
  pre-regalloc invariant; this ADR's placement codifies the
  pre-regalloc optimisation slot.

### Negative

- **MVP hoists only constants.** Bigger wins (`global.get`,
  loop-invariant arithmetic, loads) are deferred to Phase 15.
  Acceptable: P14's "simplest correct implementation" holds.
- **No constant pooling.** Two identical constants in the same
  loop both hoist independently. Wastes ~1 instr each and a
  vreg slot. Phase 15 cleanup.
- **PC-shift cost.** Splicing instrs into `func.instrs`
  invalidates external PC references temporarily; the pass
  updates `func.blocks[]` + `func.branch_targets[]` in lockstep.
  Test coverage must verify branch targets remain correct
  post-hoist.

### Neutral / follow-ups

- `loop_info.compute()` integration into `compileWasm` becomes
  load-bearing (it was reserved infra until now). The pass
  computes-or-borrows; first call in the pipeline owns the
  computation.
- `ConstantPool` (`src/ir/analysis/const_prop.zig`) docstring
  mentions Phase 15 hoisting as the consumer of its output;
  this MVP doesn't read `ConstantPool` (constants are extracted
  directly from `*.const` opcodes). A future merger between
  `const_prop.zig` and the hoist pass is a Phase 15 candidate.

## References

- ROADMAP §9.8 / 8.4 (this ADR's source row)
- ROADMAP §P13 (day-1 `?Liveness` slot rationale)
- ROADMAP §P14 (optimisation lands last in commit order)
- ADR-0014 (ZIR redesign + regalloc invariants)
- ADR-0019 (Phase 8 scope shift to optimisation foundation)
- W54-postmortem (`~/Documents/MyProducts/zwasm/.dev/archive/
  w54-redesign-postmortem.md`) — why post-regalloc hoist broke
  x86 in v1
- Cranelift `loop_analysis.rs` (`~/Documents/OSS/wasmtime/
  cranelift/codegen/src/loop_analysis.rs`) — reference; rejected
  for v2 per Alternative C
- Survey: `private/notes/p8-8.4-survey.md` (gitignored;
  re-derivable from the codebase per `lessons_vs_adr.md`)
- Existing infra:
  - `src/ir/zir.zig:434-580` (LoopInfo, HoistedConst, ZirFunc
    slots)
  - `src/ir/analysis/loop_info.zig` (loop detection)
  - `src/ir/analysis/liveness.zig` (vreg ranges)
  - `src/engine/codegen/shared/compile.zig:95` (pipeline
    integration point)

## Revision history

| Date       | Commit       | Summary                            |
|------------|--------------|------------------------------------|
| 2026-05-08 | `d0f0be64` | Initial Decision; constant-hoist MVP scope; pre-regalloc placement; per-arch backends inherit unchanged. |
| 2026-05-08 | `2f26e01b` | **Refinement**: D-053 redesign progressed — `zir.zig` gains `totalLocalCount()` + `localValType(idx)` helpers + `synthetic_locals: ?[]ValType` slot + `HoistedConst` field expansion (local_idx/prologue_const_pc/prologue_set_pc/in_loop_pc); 4 emit consumer sites in `arm64/emit.zig` and `x86_64/emit.zig` migrated to the helpers; `src/ir/hoist/pass.zig` rewritten with the local-set/local-get rewrite semantic + 4 unit tests pass. Pipeline integration attempted but **reverted again** — realworld_run_jit regressed 52/55+15 → 42/55+8 with `UnsupportedOp` from arm64 emit; no `arm64/emit:` debug print fired, narrowing the cause to one of the silent UnsupportedOp returns (lines 200, 301, 308, 324, 337, 354, 378, 745, 750, 782, 792, 795, 818, 827, 830, 853, 1155). Source localisation deferred to a fresh cycle. Lesson `2026-05-08-hoist-vreg-semantic.md` updated with the 2nd-attempt findings. |
| 2026-05-09 | `34a3ac122` | **Gap — D-053 root cause discharged**: the hoist module's `pc_shift[]` adjustment for `func.branch_targets[]` was treating depth values as PCs. Per `lower.zig:emitBrTable` + `arm64/op_control.zig:emitBranchToDepth`, branch_targets entries are Wasm br/br_table block-stack depths, not PCs. At cap=4 the spurious shift produced small Δ that coincidentally landed on valid block-stack indices; cap > ~10-20 inflated depths past `labels.items.len`, triggering `br_table UnsupportedOp` on 10/55 realworld fixtures. Fix: removed the `branch_targets[]` shift loop entirely (depths are invariant under PC shift); rewrote the existing test "shifts branch_targets across hoist prologue" as "leaves depths invariant"; **`max_hoists_per_func = 4` cap fully removed**. Mac local realworld_run_jit baseline preserved (52/55 compile-pass + 15/55 RUN-JIT-VERIFIED) with no cap. Lesson: `.dev/lessons/2026-05-09-hoist-branch-targets-as-pc.md` (single-type-two-axes failure mode + small-input-test-mask anti-pattern). Discovery enabled by 8a.1 / 8a.2 / 8a.5-b infra (per-pass diagnostic + arm64/emit failing-op errdefer + cap-removed reproducer). D-053 closed. D-054 (OrbStack-only as-loop-broke spec_assert) reframed as INDEPENDENT root cause (same 0xFD1BD386 value pre/post fix; not the branch_targets bug). |
| 2026-05-08 | `ac9de7ed` | **Gap (per `adr-revision-history-misuse` categorisation)**: the original Decision's claim "moving a `*.const` instruction backward in the instr stream therefore preserves vreg identity" was **wrong**. ZIR vreg IDs are renumbered by liveness based on operand-stack push order (`src/ir/analysis/liveness.zig:1-9`), so any instr move re-numbers all downstream vregs. Additionally, Wasm's frame-scoped operand stack (`loop` opens a fresh in-frame stack) means a hoisted const above the loop is invisible to consumers inside the loop. Naive instr-move is therefore semantically incorrect. **Discovery**: 8.4-c integration regressed `realworld_run_jit` from 52/55 compile + 15/55 RUN-PASS to 38/55 compile + 2/55 RUN-PASS. **Resolution**: integration reverted in the same commit; the 8.4-b MVP module (`src/ir/hoist/pass.zig`) preserved as code but not wired. **Correct semantic** for hoist is the **local-set / local-get rewrite**: insert `*.const K; local.set N` (with N a fresh local index) before the loop; replace each in-loop `*.const K` with `local.get N`. This decouples the value's lifetime from operand-stack scope. Tracked as D-053; redesign deferred to a Phase 8 follow-up cycle. Lesson: `.dev/lessons/2026-05-08-hoist-vreg-semantic.md`. |
