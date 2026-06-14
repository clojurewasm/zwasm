# 0037 — Regalloc upgrade: slot reuse on dead vregs (Phase 8b MVP)

- **Status**: Closed (Phase 8 DONE)
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8b / 8b.2-b autonomous /continue cycle
- **Tags**: roadmap, phase8, jit, regalloc, optimisation

## Context

`src/engine/codegen/shared/regalloc.zig` (greedy-local, ~445
lines) was the Phase 7.1 baseline allocator: every vreg gets a
fresh slot, no reuse, no live-range shaping. This made the
allocator trivially correct for backend parity (P7) but is the
direct cause of:

- **Stack-frame bloat under post-hoist IR.** ADR-0031's hoist
  pass introduces synthetic locals; without slot reuse, every
  hoisted constant pays a fresh slot for the entire function
  body. The 8a.5 hoist cap-removal commit (`b2b47f8`) preserved
  baseline correctness but did not exercise improved frame
  density — there was no allocator mechanism to reuse slots
  between dead and live vregs.
- **D-029 parallel-move blocker.** Phase 7 close left D-029
  open: the greedy-local shape provides no live-range
  information for the allocator to reason about move-cycle
  insertion. ADR-0035's coalescer scaffolding deliberately
  stays clear of parallel-moves (per its A12-aligned divergence
  from regalloc2), so D-029's resolution must come from the
  allocator side.
- **Bench-delta target for 8b.4.** §9.8b / 8b.4 requires ≥10%
  aggregate improvement on at least 3 v1-class hyperfine
  fixtures. The Phase 7 close baseline (`bench/results/
  history.yaml` SHA `bf138df`) leaves substantial allocator-
  driven headroom on loop-heavy fixtures (tinygo/fib_loop,
  shootout/nestedloop) where greedy-local's per-vreg-slot cost
  dominates frame size.

Step 0 survey (8b.2-a, `private/notes/p8-8b2-regalloc-survey.md`,
496 lines, gitignored) covered:

- **regalloc2 (cranelift)**: full backtracking + linear-scan,
  ~7K LOC core, parallel-moves, scratch-register cycles. Out
  of scope for P6 single-pass JIT.
- **wasmtime/winch**: 74-line freelist allocator on operand-
  stack tracker; no liveness analysis. Closer to P6 single-
  pass but discards IR-based reuse opportunities.
- **wasmer singlepass**: similar shape to winch.
- **zwasm v1 W43-W45 (post-mortem `~/Documents/MyProducts/
  zwasm/.dev/archive/w54-redesign-postmortem.md`)**: linear-
  scan with late-bound liveness; broke x86_64 because
  regalloc-stage IR shape implicitly assumed an absent
  invariant. v2 mitigates structurally — `?Liveness` is a
  const-input slot in `ZirFunc` from day 1 (P13).

The survey identified three structural divergences zwasm v2
should take from regalloc2 / cranelift:

1. **No parallel-move insertion** in 8b.2 (per P6 single-pass
   + ADR-0035): coalesce-time MOV elimination is the v2
   mechanism, not allocator-time move scheduling.
2. **Straight-line liveness only** in 8b.2 (per P3 cold-start
   + P6 single-pass): full CFG support deferred to Phase 14+
   (Wasm 3.0 / EH / try_table). Loops are handled via
   liveness's existing `loop_carry` set (already const-input).
3. **Slot-id ABI stability** (per ADR-0018 + ADR-0035): the
   `Allocation.slots[]` interface remains unchanged. Interior
   refactoring (splitting, reuse) is invisible to downstream
   emit + coalescer.

## Decision

**Adopt Option 1 (slot reuse on dead vregs) as the 8b.2-c MVP.**
Implement a linear-scan-style allocator pass over the existing
straight-line liveness output (already const-input per P13),
freeing slots whose vregs have ended (`liveness.last_use[v] <
current_pc`) and reusing them for vregs starting at or after
the free point.

The mechanism:

1. Walk `func.instrs.items` in PC order, mirroring
   `regalloc.compute`'s current shape.
2. Maintain a **free-slot pool** (FIFO or stack of available
   slot ids, initially empty).
3. At each ZIR instr, before allocating slots for the def-set:
   - For each vreg in `liveness.last_use_at_pc[current_pc]`,
     return its slot to the free pool.
4. For each new vreg in `liveness.def_at_pc[current_pc]`:
   - If the free pool is non-empty, pop and reuse.
   - Else allocate a fresh slot (`n_slots += 1`).

The existing `Allocation { slots: []u16, n_slots: u16 }` ABI
is **preserved unchanged**. Downstream consumers (`arm64/emit.
zig`, `x86_64/emit.zig`, `src/ir/coalesce/pass.zig` per the
just-landed Zone-1 fix) require no source change.

### Out of scope for 8b.2 (deferred)

- **Live-range splitting at loop boundaries** (Option 2 in
  the survey, ~5-10% additional win on loop-heavy fixtures):
  introduces split-points that require per-arch emit
  awareness OR coalescer-time fix-up. Defer to **Phase 15**
  alongside the coalescer detection lift (per ADR-0036). At
  Phase 15 the allocator output naturally surfaces same-slot
  alias conditions that the coalescer's existing
  `func.coalesced_movs` slot can record.
- **Full SSA-based linear-scan with CFG edges** (Option 3 in
  the survey): out of scope for a P6 single-pass JIT;
  consider for Phase 14+ (Wasm 3.0 GC / EH backend) if and
  when the IR substrate gains explicit CFG.
- **Spill-to-memory escalation**: current allocator already
  handles spills via the per-arch `spill_aware` discipline
  (see `.claude/rules/spec_citation.md` sibling material on
  D-034). 8b.2 does not change spill timing or placement.

### Concrete revised exit criterion (8b.2)

8b.2-c marks `[x]` when:

- `regalloc.compute` adds free-slot pool + last-use return
  logic.
- `Allocation` ABI unchanged.
- Existing `regalloc.zig` unit tests + coalescer scaffolding
  tests + `compile.zig` pipeline tests all pass.
- New unit test: a 3-vreg sequential-use program produces
  `n_slots = 1` (proves reuse), where the previous shape
  produced `n_slots = 3`.

8b.2-d marks `[x]` when:

- `compile.zig` integration green.
- Bench-delta capture against tinygo/fib_loop +
  shootout/nestedloop + tinygo/string_ops via
  `scripts/run_bench.sh --diff <pre-8b.2-c-sha>`. Per
  ADR-0032: bench-delta table required in commit body.
- Regression check: every other v1-class fixture stays
  within ±2% of baseline (no allocator-induced regression).

8b.2-e marks `[x]` when 3-host gate green and 8b.2 row in
ROADMAP §9.8b flips `[x]`.

## Alternatives considered

### Alternative A — Option 2 (live-range splitting at loop boundaries)

- **Sketch**: split each vreg's live-range at every loop
  header; allocate each segment to a different slot to maximize
  per-region density.
- **Why deferred to Phase 15**:
  1. Splits introduce **MOV insertion** at split points, which
     contradicts the P6 single-pass / ADR-0035 metadata-only-
     coalesce design. The 8b.1 coalescer scaffolding has no
     mechanism for splits-induced MOVs because Phase 8b's
     scope (per ADR-0036) excluded detection logic.
  2. The W54-class regression risk is highest here: a split
     point that the allocator computes but emit doesn't see
     produces silent corruption (the v1 W54 failure mode).
  3. Bench-delta evidence from upstream references (cranelift
     splits give ~5-10% additional wins; Phase 15 will get
     them when coalescer detection layers in).

### Alternative B — Option 3 (full linear-scan with CFG edges)

- **Sketch**: build a proper CFG, compute live-in/live-out per
  block, allocate with backtracking on conflict.
- **Why rejected**: ~600+ LOC, breaks single-pass JIT
  contract (P6), requires CFG infrastructure that the IR
  substrate doesn't have. The complexity buys at most ~5%
  over Option 2 on synthetic benchmarks. Out of scope for
  Phase 8; revisit if and when Phase 14+ adds CFG-shaped IR
  for Wasm 3.0 EH (try_table multi-target dispatch is the
  natural CFG trigger).

### Alternative C — Adopt regalloc2 directly (FFI / wrapper)

- **Sketch**: link regalloc2 (Rust) into zwasm via cdylib
  + extern interface. Use cranelift's allocator output
  directly.
- **Why rejected**:
  1. P10 no-copy from v1 doesn't apply (regalloc2 is
     upstream Rust), but introduces a Rust dependency on a
     pure-Zig project — violates ADR-0001's "minimum
     external dependencies" stance.
  2. Build complexity (cargo + zig + linker) for the
     three-host gate (Mac aarch64 + OrbStack Linux x86_64
     + windowsmini) is high.
  3. regalloc2's API surface is wide (GenericFunction,
     Operand, OperandKind, RegClass…); the impedance
     mismatch with `Allocation { slots, n_slots }` would
     either require a thick adapter layer (defeating the
     point of using upstream) or a wholesale ABI change
     (breaking ADR-0018 + ADR-0035 stability guarantee).

### Alternative D — Adopt winch's free-list directly (no liveness)

- **Sketch**: drop liveness analysis; track operand-stack
  vreg lifetimes inline in the allocator pass.
- **Why rejected**:
  1. Discards the P13 liveness-as-const-input invariant —
     the very mechanism that prevents W54-class regressions.
  2. winch's design works because winch is **an emit pass
     that does its own allocation inline**; there is no IR
     representation to consume liveness from. zwasm v2 has
     a separate ZIR substrate and gains nothing by collapsing
     the boundary.
  3. The free-list pool from this ADR is structurally
     similar to winch's tracker BUT consumes the existing
     `?Liveness` slot — best of both worlds.

## Consequences

### Positive

- **Smallest viable surface for the 8b.2 MVP**: ~200 LOC
  diff in `regalloc.zig`, ~50 LOC of new tests. ABI
  preserved.
- **Foundation for Phase 15 coalescer detection lift**: the
  free-slot pool directly produces same-slot aliasing events
  (when vreg V's slot is reused for vreg W). Phase 15's
  detection layer can subscribe to those events without re-
  walking the IR.
- **D-029 parallel-move resolution path**: not directly
  resolved by 8b.2-c, but the free-slot pool mechanism is
  the substrate Phase 15 will build the parallel-move
  detector on.
- **W54 mitigation preserved**: `?Liveness` stays as
  const-input; the allocator never mutates it. The free-
  slot pool's correctness is provable by the property
  "every slot is in the pool iff no live vreg currently
  occupies it" — local invariant, no IR-shape assumption.

### Negative

- **8b.4 ≥10% aggregate at risk**: Option 1 alone delivers
  ~3-5% on most loop-heavy fixtures per the survey. To hit
  ≥10% on 3+ fixtures, 8b.3 (AOT skeleton) and the residual
  8a.5 hoist-cap-removal contribution must carry the
  remaining ~5-7%. If 8b.4 measurement shows the aggregate
  still short of 10%, 8b.2-d gets a follow-on Option 2 lift
  (live-range splitting) or 8b.4 gets a deferred-row
  amendment.
- **Slot-reuse heuristics**: FIFO vs LIFO vs nearest-fit
  for the free pool produces different bench results.
  8b.2-c starts with **LIFO (stack)** for cache-locality
  preservation; 8b.2-d may switch to nearest-fit if bench
  evidence demands. The choice is encoded as a single
  function in `regalloc.zig` for trivial ratchet.
- **Phase 15 coalescer detection lift now structurally
  depends on this allocator**: if Phase 15 starts before
  this allocator lands (unlikely given ROADMAP order but
  worth stating), the detection layer has no same-slot
  events to subscribe to.

### Neutral / follow-ups

- **Optimisation log**: record this as O-NNN entry per
  `.dev/optimisation_log.md` discipline once 8b.2-d's
  bench-delta lands.
- **bench-delta capture**: 8b.2-d uses the
  `scripts/run_bench.sh --diff <pre-8b.2-c-sha>` mechanism
  per ADR-0032. The diff is captured against the
  pre-allocator-change SHA, not the entire 8b.2-c series,
  to isolate the allocator's contribution.
- **D-029 status update**: ROADMAP §14 / debt ledger row
  updated when 8b.2-d closes — current `blocked-by:
  Phase 8b foundation` barrier dissolves to `blocked-by:
  Phase 15 coalescer detection` (the actual structural
  prerequisite for parallel-move).

## References

- ROADMAP §9.8b / 8b.2 (Regalloc upgrade), §9.8b / 8b.4
  (≥10% aggregate exit), §P3 (cold-start), §P6 (single-
  pass JIT), §P7 (backend parity), §P10 (no copy from v1),
  §P13 (liveness const input), §A12 (no per-arch logic in
  shared code), §14 forbidden list (single field two
  semantic axes — load-bearing for ABI stability claim)
- ADR-0018 (`Allocation` ABI shape)
- ADR-0027 (greedy-local regalloc; foundation this ADR
  upgrades)
- ADR-0031 (hoist pass; constraint that motivated 8b.2)
- ADR-0032 (Phase 8 foundation-first reorg; bench-driven
  discipline)
- ADR-0035 (post-regalloc slot-aliasing coalescer; ABI
  stability consumer)
- ADR-0036 (8b.1 scope downgrade; Phase 15 detection lift
  predecessor)
- 8b.2-a survey: `private/notes/p8-8b2-regalloc-survey.md`
  (gitignored)
- v1 W54 post-mortem: `~/Documents/MyProducts/zwasm/.dev/
  archive/w54-redesign-postmortem.md` (W54-class
  regression model)
- regalloc2 reference: `~/Documents/OSS/regalloc2/src/
  lib.rs` (algorithm catalog)
- wasmtime/winch reference: `~/Documents/OSS/wasmtime/
  winch/codegen/src/regalloc.rs` (P6 single-pass anchor)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `8381dfb0` | Initial accepted version (§9.8b / 8b.2-b design framing; Option 1 slot-reuse MVP, Options 2-3 deferred to Phase 15) |
| 2026-06-15 | `6790c204` | **Correctness amendment (D-330): expiry boundary `<=` → `<` (strict).** The free-pool expiry freed an active vreg's slot when `active.last_use_pc <= new.def_pc`, coalescing a result vreg into the slot of an operand the SAME instruction reads (their closed live intervals `[def,last_use]` overlap at that pc). Sound ONLY if every op emit reads all operands before writing its result — an unenforced invariant, violated by an op in emscripten musl's `strnlen` byte-loop inside `vfprintf`: plain `%s` (`strnlen(s, SIZE_MAX)` null check) miscompiled → empty `%s` + dropped `\n`, corrupting `c_sha256_hash` + `emcc_fasta` under `--engine jit`/AOT (interp correct; arch-INDEPENDENT — identical on arm64 + x86_64-Rosetta ⇒ shared-codegen, not arch-emit). Fix = strict `<`: a result slot never aliases an operand the defining op reads, so per-op read-before-write discipline is unnecessary (misuse-resistant; the correct closed-interval overlap test). Cost ~+1 slot on the worst realworld fn (`vfprintf` 12→13) — negligible; `zig build test` + `test-spec` green, `emcc_fasta` byte-exact. Updated the test that pinned the old coalescing. Trail: `private/spikes/jit-vararg/` + lesson [`2026-06-15-regalloc-boundary-coalesce-read-after-write`](../lessons/2026-06-15-regalloc-boundary-coalesce-read-after-write.md). (A residual single dropped `\n` in `c_sha256_hash` is a SEPARATE bug exposed once this one was fixed → D-330 residual.) |
| 2026-05-09 | `c7b0ea5e` | **Discovery during 8b.2-c implementation**: the current `regalloc.compute` busy-mask scan (`busy[slots[ev]] = true if earlier.last_use_pc > r.def_pc`) **already implements slot reuse on dead vregs**. The Step 0 survey misread "greedy-local" as "no reuse"; reading the actual code reveals the busy-mask check is an inline form of "is the earlier vreg still live at my def_pc". Test "two non-overlapping ranges share slot 0" (line 273) was the existing regression check; "three sequential non-overlapping ranges all share slot 0" (this commit) extends it. Reframe 8b.2-c: free-pool refactor stands as algorithmic cleanup (busy-mask scan with 4 KiB `@memset` per vreg → LIFO free-pool, O(n²) constant-factor reduction) + Phase 15 substrate (free-pool pops surface as same-slot reuse events the coalescer can subscribe to). **Bench-delta is 0% by construction**, not the ~3-5% the survey anticipated. The runtime-bench wins ADR-0037 anticipated migrate to: (1) class-aware allocation per D-036 §option-b (`max_reg_slots_gpr` / `max_reg_slots_fp` boundary unification produces tighter spill frames; mentioned in current `regalloc.zig:131-133` as "Tighter accounting lands when the allocator becomes class-aware"); (2) live-range splitting (Option 2, deferred to Phase 15 per original ADR-0037 framing). 8b.2-d is reframed as **class-aware spill-frame compaction** with its own ADR (ADR-0038 to follow) before implementation. See lesson [`2026-05-09-greedy-local-already-does-reuse`](../lessons/2026-05-09-greedy-local-already-does-reuse.md). |
