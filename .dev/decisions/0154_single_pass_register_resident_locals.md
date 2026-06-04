# 0154 — Single-pass register-resident locals (D-265 rework, Phase III design)

- **Status**: Proposed (2026-06-04; D-265 rework campaign Phase III per ADR-0153; validation spike pending)
- **Date**: 2026-06-04
- **Author**: claude (autonomous, D-265 campaign Phase III)
- **Tags**: Phase 15, perf, regalloc, liveness, ZIR, single-pass, D-265, ADR-0149, ADR-0150, ADR-0153, W54
- **Amends**: ROADMAP §15.P (parity-achievement mechanism). Adds a local-value-reuse cache to
  `src/ir/analysis/liveness.zig` + reuse-metadata consumption in `arm64/emit.zig` + `x86_64/emit.zig`.
  Revises ADR-0149/0150 ("~0 regalloc headroom") — see Consequences.

## Context

D-265 (campaign Phase I, `bench/results/s15p_parity_vs_v1.md`): v2-jit is ~2.3× slower than v1 when a loop body
reads a loop-carried local. MECHANISM: every `local.get $i` mints a fresh vreg + `LDR [SP,#local_slot]`
(`arm64/emit.zig:910-968`); there is no value residency, so a local read N times in a hot loop hits memory N
times. v1 keeps the local register-resident. Phase II pinned the correct behaviour with 3 characterization
fixtures (`test/edge_cases/p9/regalloc/loop_carried_local_sum|local_set_then_get_in_loop|multi_local_loop_pressure`,
3-host green) — the rework's regression net.

Pipeline facts (Phase III survey): vregs are minted in **liveness** (`liveness.zig:552-560`, one fresh vreg per
operand-stack push, generic — `local.get` is just "pushes 1"); regalloc (`shared/regalloc_compute.zig`) is a
greedy-local scan over live ranges with NO semantic awareness of locals; both emit backends walk the same ZIR
stream and must mint vregs in the SAME order as liveness (the slot array is indexed by that shared numbering).
Constraint: P3/P6 single-pass — no SSA, no multi-pass IR optimisation (§3.2: optimising tier permanently
post-v0.1.0). v1's locals-in-registers is ALSO single-pass, so parity is achievable within P3/P6.

## Decision

**Add a local-value-reuse cache to liveness; both emit backends consume the resulting per-`local.get` reuse
metadata. Regalloc is unchanged.** (Option A of the Phase III survey; Option B — pinning locals to fixed regalloc
slots — rejected: needs is-local metadata plumbing into the class-blind allocator + higher W54 risk.)

**Mechanism.** Liveness gains `local_live_vreg: [n_locals]?u32` (init null). Walking the ZIR stream:
- On `local.get $i`: if `local_live_vreg[i]` is non-null (still valid), **re-push that existing vreg** onto the
  sim-stack (do NOT mint a fresh one) — the eventual pop extends its `last_use_pc`. Else mint fresh (today's
  behaviour) and set `local_live_vreg[i]`. Record per-pc metadata: `reuse(vreg)` or `fresh`.
- On `local.set $i` / `local.tee $i`: `local_live_vreg[i] = null` (invalidate — no stale read).
- On any control-flow boundary (`block`/`loop`/`if`/`else`/`end`): **clear ALL** entries (conservative merge
  fence — a value cached before a join cannot be assumed register-resident after).
- **GcRef locals: NEVER cache** (always `null`) — a reference held only in a register is invisible to the
  conservative native-stack GC scan (`scanNativeStackRoots`); keeping it slot-resident is the Phase-II
  GcRef-slot constraint (D-261/D-258). The local's type is available at liveness time.

**Emit** (both backends) reads the reuse metadata: a `reuse(vreg)` `local.get` emits **no LDR** and does not
increment `next_vreg` — it pushes the existing vreg (value already materialised in its register/slot, kept live
by the extended range). A `fresh` `local.get` is unchanged. This keeps liveness/emit vreg numbering in lockstep.

**Why it is correct (the load-bearing invariant).** Re-pushing the cached vreg EXTENDS its live range to the
later use, so regalloc keeps it allocated across the intervening ops (it will NOT reuse that register for an
intervening result). Thus the second `local.get` reads the still-valid value. If the range were not extended, a
later result could clobber the register → wrong value; the extension is what makes reuse sound. The Phase-II
fixtures (loop-carried read; write-then-read; multi-local) are the executable proof.

## Anti-regression invariants (MUST hold; W54 lineage)

1. **Write invalidates** — `local.set`/`local.tee $i` clears `local_live_vreg[i]` before the value is consumed.
2. **Merge fence** — every block/loop/if/else/end clears the whole cache (no cross-join residency assumption).
3. **GcRef slot-residency** — reference-typed locals are never cached → always spill-slot resident → findable by
   the GC scan (closes the D-261 interaction the rework would otherwise worsen).
4. **Liveness/emit lockstep** — emit consumes liveness's metadata; it never makes an independent reuse decision
   (single source of truth for vreg numbering).

## Incremental migration (Phase IV, behaviour-preserving, net green at EVERY commit)

1. Liveness computes the cache + metadata but emit IGNORES it (metadata unused) — behaviour-identical; lands the
   plumbing green.
2. arm64 emit consumes the metadata (reuse → skip LDR). Full test net + Phase-II fixtures green; measure w45_addi.
3. x86_64 emit consumes it (P7 both-backends-equal). ubuntu test-all green (cross-compile≠cross-run, D-262).
4. The merge-fence + GcRef guard land WITH step 1 (not after) so no intermediate state is unsound.

## Exit criterion

w45_addi **2.3× → ≤1.1× vs v1** (the D-265 ROI target) AND the full test net (spec 100% + edge_cases incl. the 3
Phase-II fixtures + realworld + differential) green on 3 hosts. Phase V: ADR-0149/0150 Revision note.

## Validation spike (before on-branch impl, per ADR-0153 Phase III + spike_discipline)

`private/spikes/regalloc-local-cache/`: implement the liveness cache + arm64 reuse-emit minimally, run the
Phase-II fixtures (must stay green = correctness) + w45_addi (must approach v1 = ROI). If green + ROI holds →
land per the migration above. If a correctness fixture breaks or ROI is thin → revise (the cache is too
aggressive / the range-extension is mis-modelled) before any on-branch code.

## Rejected alternatives

- **Option B (pin locals to fixed regalloc slots, v1-literal)** — requires threading is-local metadata into the
  class-blind allocator + a pre-pass; higher W54 risk; more structural coupling. Option A reuses the existing
  liveness→regalloc contract (just longer ranges).
- **Post-emit redundant-load peephole** — a separate pass over emitted code = violates P6 single-pass.
- **Defer past v0.1.0** — contradicts §1.2 (parity is the v0.1.0 line) + the design priority (ADR-0153).

## Consequences

- Closes the D-265 parity gap within P3/P6 (better single-pass baseline regalloc, not an optimising tier).
- **Revises ADR-0149/0150**: their "~0 regalloc headroom" held for spill-MOV-traffic-as-%-of-total-instrs but
  MISSED the loop-local reload cost (a reload in a 3-instr hot loop is ~0% of the program, ~2× of that loop). The
  headroom is real on the loop-local pattern. A Revision note lands at Phase V.
- Regalloc, ZIR shape, and the spill-everything model for temporaries are UNCHANGED — only locals gain residency
  via extended ranges. Low blast radius beyond liveness + the two emit `local.get` arms.
