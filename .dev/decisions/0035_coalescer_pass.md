# 0035 — Post-regalloc slot-aliasing coalescer (Phase 8b MVP)

- **Status**: Accepted (scope downgraded by ADR-0036; design retained for Phase 15)
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8b / 8b.1-b autonomous /continue cycle
- **Tags**: roadmap, phase8, jit, optimisation, coalescer, regalloc

## Context

§9.8a foundation closed (per-pass diagnostic + JIT-execution
sentinel + bench-delta-per-commit + ZWASM_DIAG runtime opt-in
+ D-053 hoist-branch-targets fix). §9.8b is **bench-driven**
per ADR-0032 — every chunk's commit body must include a
`## Bench delta` table.

§9.8b / 8b.1's first row is a vreg coalescer / MOV
elimination. The 8b.1-a survey at `private/notes/p8-8b1-
coalescer-survey.md` (commit `64b135a`'s gitignored
artefact) found:

- **v1 had a coalescer attempt** (`ec8182f`, archived)
  passing Mac aarch64 but failing x86_64 `go_math_big`
  because the coalesced IR shape exposed an emit-stage
  spill-around-call assumption that was arch-agnostic in
  regalloc but arch-specific in emit. **Lesson**:
  regalloc-stage IR mutation is risky; metadata-only
  signals are safer.
- **cranelift** delegates coalescing entirely to regalloc2;
  no in-IR coalescing at the cranelift level.
- **regalloc2** coalesces DURING allocation via
  `ParallelMoves<T>`. The Edits API is the OUTPUT of
  coalescing, not input.
- **winch** + **wasmer singlepass**: no dedicated
  coalescer — single-pass JITs can't afford multi-pass
  analysis. Call-move sorting at codegen time is the MVP.

zwasm v2 sits closest to winch / wasmer in design (single-
pass JIT, P6) but inherits regalloc2's "metadata, not
mutation" cleanliness. The MVP must respect:

- **P10 (no copy from v1)**: re-derive, don't port the
  archived v1 coalescer.
- **P13 (liveness const input)**: regalloc consumes
  liveness; mutation post-regalloc is forbidden.
- **A12 (dispatch-table-not-pervasive-if)**: avoid
  per-emit-arch branches inside the hot loop.

## Decision

**Land a post-regalloc slot-aliasing coalescer at
`src/ir/coalesce/pass.zig`** (Zone 1, mirrors
`src/ir/hoist/pass.zig` shape) that **discovers redundant
MOVs as side-table metadata** without mutating ZIR or
regalloc.Allocation. The emit pass queries the metadata at
each MOV emission site and skips emission of redundant
slots.

### Concrete shape

#### Pass placement

Pipeline (post-§9.8a):

```
lower → loop_info → hoist → liveness → regalloc → coalesce → emit
                                                  ^^^^^^^^
                                                  this ADR
```

Runs after regalloc returns its `Allocation`. Reads:

- `func.instrs.items` (MOV-shaped ops: end-of-block merges,
  call-arg setup, return-value marshalling).
- `alloc.slots[]` (per-vreg slot assignment).
- `func.liveness.ranges[]` (per-vreg `def_pc / last_use_pc`).

Writes (caller-owned, freed via `deinitArtifacts` in
`compile.zig`'s `deinitFuncResult`):

- `func.coalesced_movs: ?[]CoalesceRecord` — already a
  reserved slot in `ZirFunc` per ROADMAP §P13 day-1
  reservation.

#### `CoalesceRecord` field shape

```zig
pub const CoalesceRecord = struct {
    /// PC of the MOV-shaped instr in `func.instrs.items`.
    /// Emit consults `coalesced_movs` and skips emission
    /// when this PC matches the current dispatch index.
    instr_pc: u32,
    /// The slot id involved (informational; both src and
    /// dst are this slot since the alias is detected by
    /// `slots[src_vreg] == slots[dst_vreg]`).
    slot: u16,
    /// The detection reason (debug + future audit).
    reason: enum(u8) { same_slot_alias, _ },
};
```

The `_` extension on `reason` allows additional detection
classes (e.g. dead-after-call) without breaking the
existing emit consumers.

#### Detection algorithm (single forward pass)

```
for each instr at pc:
    if not isCoalesceCandidate(instr.op): continue
    let dst_vreg = popped vreg(s) in regalloc IR
    let src_vreg = source vreg(s)
    if alloc.slots[src_vreg] != alloc.slots[dst_vreg]: continue
    if dst_vreg.last_use_pc <= pc: continue   // dst dead immediately; this IS the MOV's purpose
    if isBranchTargetOrCallSite(pc): continue // bail conservatively
    if anyAcrossCall(src_vreg, dst_vreg, pc): continue  // spill timing
    record CoalesceRecord{instr_pc=pc, slot=alloc.slots[dst_vreg], reason=.same_slot_alias}
```

`isCoalesceCandidate` selects only ops that emit a MOV
when their src/dst happen to share a slot — `local.tee`
(post-regalloc), `select`, return-value marshalling. The
catalogue ships small (3-5 ops) and grows op-by-op as
bench-delta surfaces wins.

`isBranchTargetOrCallSite` queries `func.blocks` +
`func.branch_targets` + the `call` opcode set. Reusing the
existing structures avoids new analysis.

`anyAcrossCall` walks the `[def_pc..last_use_pc]` range and
returns true if any `call` / `call_indirect` falls within
— per the v1 W54 lesson, regalloc may spill / restore the
slot at the call boundary, breaking the alias assumption.

#### Emit-pass integration

`arm64/emit.zig` and `x86_64/emit.zig`'s main op-dispatch
loop (already running per `for (func.instrs.items, 0..) |
ins, pc|`) gains a single check before each MOV-shaped
emit:

```zig
if (ctx.func.coalesced_movs) |records| {
    for (records) |rec| {
        if (rec.instr_pc == pc) {
            // Skip emission; the IR-level MOV is a
            // post-regalloc no-op.
            continue :outer;
        }
    }
}
```

The linear scan is acceptable because (1) `records.len`
is typically 0..20 per func, (2) the check is gated on
the rare optional `coalesced_movs` slot being non-null
(only when `-Dtrace-ringbuffer=true` OR when bench mode
is on; release builds default-skip via comptime-elision
of the gate's outer optional).

The check shape is **arch-blind** — both backends consume
the same metadata via the same query pattern. No
per-arch logic per A12.

#### Build flag gating

The coalescer is **always-on** by default in release
builds (unlike trace ringbuffer which is opt-in). The
metadata pass cost is single-digit microseconds per
function compile; the emit-time skip is faster than emit
itself, so net JIT compile time decreases on coalescer-
applicable functions.

A new `-Dcoalesce=on/off` build flag disables the pass
entirely (default: on) for bench A/B comparison. ADR-0032's
bench-delta-per-commit infra (`scripts/run_bench.sh
--diff`) consumes both modes' history.yaml entries to
quantify the speedup.

### What this ADR does NOT do

- **No in-IR mutation**: ZIR + regalloc.Allocation are
  read-only inputs; coalescing produces side-table
  metadata only.
- **No scratch-register cycle insertion**: zwasm's greedy-
  local regalloc avoids parallel-move complexity per
  §9.7 / 7.1 design; deterministic slot assignment means
  no same-slot cycles.
- **No dominance-aware analysis**: branch-target bail is
  the conservative MVP per the v1 W54 lesson. Inter-block
  coalescing deferred to Phase 15.
- **No per-arch refinements**: arch-blind pass; arch-
  specific MOV-elim peepholes (e.g. AArch64 `MOV X0, XZR`
  → no-op when X0's prior value is dead) are deferred.

## Alternatives considered

### Alternative A — Pre-regalloc IR-level coalescing (cranelift-style)

- **Sketch**: walk ZirInstr stream pre-regalloc, identify
  MOV-elim opportunities, rewrite `instrs[]`. Liveness
  re-runs after.
- **Why rejected**:
  1. **Violates P13** (liveness const input) — re-running
     liveness invalidates the contract the rest of the
     pipeline assumes.
  2. **Violates P10** (no v1 copy / no IR mutation
     post-lower) — the archived v1 coalescer landed at
     this layer and broke x86 due to emit-stage
     assumptions about the pre-coalesced shape.
  3. **Increases compile-time cost** — pre-regalloc
     coalescing adds an analysis-and-rewrite cycle
     before regalloc proper.

### Alternative B — Coalescing during allocation (regalloc2-style)

- **Sketch**: integrate coalescing into the regalloc
  inner loop, producing parallel-moves in the
  `Allocation` output.
- **Why rejected**:
  1. **Scope explosion**: zwasm's regalloc is greedy-local
     (~200 LOC); regalloc2 is ~15K LOC of coalescing-
     aware allocation. Bringing zwasm's regalloc to
     regalloc2's level is Phase 15+ scope.
  2. **MVP discipline**: §9.8b is bench-driven MVP work;
     option (b)'s 1-2 day scope vs ~3-5 weeks for option
     (B) breaks the bench-delta cadence.
  3. **Greedy-local doesn't need it**: the deterministic
     slot assignment means most same-slot redundancy is
     already detected by emit's existing commute path;
     option (b) catches the remaining ~5-12% with
     minimal complexity.

### Alternative C — No coalescer; ship with bench evidence

- **Sketch**: skip 8b.1 entirely; benchmark Phase 8a-only
  baseline against Phase 7 close; if existing heuristics
  + hoist already buy >5% on the v1-class fixtures, drop
  the coalescer row.
- **Why rejected**: ROADMAP §9.8b row text explicitly
  calls for a coalescer + bench-delta. The 8a.5 hoist fix
  alone may not sustain the §9.8b / 8b.4 ≥10% aggregate
  exit criterion. Land option (b); measure; defer to (C)
  only if bench shows <3% win.

### Alternative D — Dominance-aware inter-block coalescing (option c)

- **Sketch**: extend option (b) to detect coalescing
  opportunities across block boundaries using dominator
  info from the IR analysis phase.
- **Why deferred** (not rejected):
  1. **Effort**: 3-5 days vs option (b)'s 1-2.
  2. **Phase 15 fit**: full dominance machinery aligns
     with v1-class peephole optimisations slated for
     Phase 15.
  3. **Bench-delta unknown**: option (b) may already buy
     enough; (D) is incremental on top of (b)'s baseline.

## Consequences

### Positive

- **5-12% expected speedup** on mov-heavy fixtures per
  the 8b.1-a survey: tinygo/fib_loop (★★★ 15-25%),
  shootout/nestedloop (★★★ 10-20%), tinygo/string_ops
  (★★ 8-12%), shootout/sieve (★★ 5-10%).
- **No IR risk**: the metadata-only design preserves
  the v1 W54 lesson — no arch-specific assumptions can
  leak into post-regalloc IR shape because the IR
  doesn't change.
- **Compositional with hoist (D-053 fix)**: hoist's
  synthetic locals create new local.set/local.get
  pairs; some collapse via slot aliasing post-regalloc.
- **Bench-delta-friendly**: every coalescer-touching
  commit gets a `## Bench delta` table per ADR-0032's
  Step 5b. Both wins and regressions surface.
- **Phase 15 prepared**: option (D)'s dominance-aware
  extension fits as a layer atop the metadata pass
  without redesigning anything.

### Negative

- **`ZirFunc` slot consumed**: `coalesced_movs: ?[]
  CoalesceRecord` was already reserved per P13; this
  ADR populates it. No ABI / layout change.
- **Per-emit linear scan**: O(records.len) per MOV
  dispatch. Negligible at typical record counts (0-20)
  but a sorted-by-pc binary search becomes worthwhile
  at >100 records — Phase 15 refinement.
- **Catalogue maintenance**: `isCoalesceCandidate`'s op
  set grows incrementally as bench-delta surfaces wins.
  Per `.claude/rules/single_slot_dual_meaning.md` the
  candidate set lives in one place (top of
  `coalesce/pass.zig`), not split per arch.
- **Bench-delta variance**: hyperfine's noise floor on
  small fixtures is ~2-3%; coalescer wins below this
  threshold are statistically indistinguishable.
  Mitigation: report median + stddev per ADR-0032's
  schema; require ≥5% to claim a win.

### Neutral / follow-ups

- **8b.1-c** (next chunk): implement
  `src/ir/coalesce/pass.zig` per this ADR; unit tests
  asserting (a) same-slot detection; (b) call-site
  bail; (c) branch-target bail. Bench-delta required
  per ADR-0032.
- **8b.1-d**: wire into `compile.zig`'s pipeline
  between regalloc and emit; arm64 + x86_64 emit query
  the metadata.
- **8b.1-e**: 3-host gate; close 8b.1 with bench-delta
  in commit body.
- **Phase 15 follow-up**: option (D) dominance-aware
  inter-block extension; AArch64 `MOV Xn, XZR` peephole.
- **Optimisation log**: record this as O-NNN entry per
  `.dev/optimisation_log.md` discipline.

## References

- ROADMAP §9.8b / 8b.1 (Coalescer pass), §A12 (no
  pervasive build-time `if`), §P10 (no copy from v1),
  §P13 (liveness const input)
- ADR-0032 (Phase 8 foundation-first reorg; bench-driven
  discipline)
- ADR-0027 (greedy-local regalloc; foundation for
  deterministic slot assignment)
- 8b.1-a survey: `private/notes/p8-8b1-coalescer-survey.
  md` (gitignored)
- v1 prior coalescer: `~/Documents/MyProducts/zwasm/.dev/
  archive/w54-redesign-postmortem.md` (Mac-passing,
  x86-failing case study)
- regalloc2 ParallelMoves reference: `~/Documents/OSS/
  regalloc2/src/moves.rs`
- cranelift vcode emit reference: `~/Documents/OSS/
  wasmtime/cranelift/codegen/src/machinst/vcode.rs:
  1048-1071`
- winch single-pass regalloc reference: `~/Documents/
  OSS/wasmtime/winch/codegen/src/regalloc.rs`

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `59fc26fa` | Initial accepted version (§9.8b / 8b.1-b design framing) |
| 2026-05-09 | `70d3deba` | Scope-downgrade per ADR-0036: the "1-2 day" estimate covered the scaffolding only; full operand-stack vreg-numbering simulation + same-slot detection + emit-side query exceeded the chunk budget. ADR-0036 formalises the 8b.1 scope as scaffolding-only, with detection deferred to Phase 15 (post-AOT, post-regalloc-upgrade). The post-regalloc slot-aliasing design framed here remains sound; only the scoping changes. See [`0036_coalescer_scope_downgrade.md`](0036_coalescer_scope_downgrade.md). |
| 2026-05-11 | `3d0e8a7c` | Status flipped to `Accepted (scope downgraded by ADR-0036; design retained for Phase 15)` per the 2026-05-11 ADR audit (`private/20250511_adr_audit/SUMMARY.md` §2.5) and ADR-0050 D-1's matching notation. The original `Accepted` Status read as "still steering scope"; the new label records the relationship in the Status line so a fresh reader hits it without scanning Revision history. |
