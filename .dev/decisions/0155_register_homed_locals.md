# 0155 — Register-homed locals, single-pass (D-265 rework, Phase III — Option B)

- **Status**: Proposed (2026-06-04; D-265 rework campaign Phase III per ADR-0153; supersedes ADR-0154's Option A
  approach; validation spike + staged Phase IV pending)
- **Date**: 2026-06-04
- **Author**: claude (autonomous, D-265 campaign Phase III redo)
- **Tags**: Phase 15, perf, regalloc, liveness, emit, single-pass, locals, D-265, ADR-0018, ADR-0149/0150/0151, W54, W45
- **Amends**: ROADMAP §15.P (parity mechanism). Adds a register-home for wasm locals to `shared/regalloc*.zig` +
  `arm64/emit.zig` + `x86_64/emit.zig` + `liveness.zig`. Supersedes ADR-0154 (Option A insufficient: ~17%).
  Re-opens the W45/loop-persistence question ADR-0151 folded (for SCALAR locals).

## Context

D-265 (campaign, `bench/results/s15p_parity_vs_v1.md`): v2-jit is ~2.3× slower than v1 when a loop body reads a
loop-carried local. Phase-III analysis (ADR-0154 Revision) proved the cost is the **per-iteration loop-top
reload**: v2 homes locals in a separate `local_base_off` stack region; `local.get $i` = `LDR` from that slot,
`local.set $i` = `STR`; so a local's value crosses the loop back-edge via MEMORY. v1 homes locals in **registers**
(vregs 0..N-1, loaded once at prologue, resident across the whole function incl. loop back-edges, spilled only
around calls) — `local.get`/`set` are register reads/writes, no per-iteration memory. This is a deliberate v2
simplification (ADR-0018 era: locals → slots) that costs the 2.3×. Per the design priority (ADR-0153) + §1.2
(parity is the v0.1.0 line), it is fixed now, within P3/P6 single-pass (v1 is the single-pass existence proof).

Phase-II correctness net (the regression guard, 3-host green): `test/edge_cases/p9/regalloc/`
loop_carried_local_sum=55, local_set_then_get_in_loop=30, multi_local_loop_pressure=84.

## Decision

**Give wasm locals a register home, single-pass (v1-style), replacing the slot-only model.** A local is a
**mutable register-resident value** for its lifetime (loaded once at prologue, read/written in-register, spilled
to its `local_base_off` slot only at necessity points), NOT a slot reloaded per access.

This is NOT the temporary-vreg model (those are single-def SSA-ish values from `liveness.zig`'s push-per-op). A
local is **multi-def mutable** (each `local.set` re-writes it). So locals need their OWN allocation concept — a
**local-register file** sized by `local_count`, allocated alongside (and competing with) the temporary-vreg slot
pool — mirroring v1's "vregs 0..N-1 are the locals." (Open design choice for the spike: a separate local-register
pre-reservation vs unifying locals into a multi-def-capable vreg space; the spike picks whichever is cleaner +
hits the ROI with lower W54 risk.)

**Mechanism (the four cross-layer touch-points):**
1. **regalloc** (`shared/regalloc*.zig`): reserve the first K physical GPR/FP slots for the first K locals (by
   type class); locals beyond K (or beyond pressure) stay slot-homed (overflow). Single-pass pre-reservation
   before the greedy temporary scan (v1: `regalloc.zig:8-10,39`).
2. **prologue** (both emit backends): load the register-homed locals from their `local_base_off` slots into their
   reserved registers once (v1: `computePrologueLoads`, `jit.zig:1997-2002`). Params + zero-inits flow in here.
3. **`local.get`/`local.set`** (both backends): a register-homed local → read/write the reserved register (no
   LDR/STR). A slot-homed (overflow) local → today's LDR/STR.
4. **necessity points** — spill the register-homed local back to its slot, then reload after: (a) **before a
   call** if the local is in a caller-saved reg (v1: `jit.zig:1705-1719`); (b) **function exit** (store final
   values if the slot is observable — usually not, but keep correctness); (c) the loop back-edge needs **NO**
   reload (the whole point — v1 `jit.zig:1639-1646` marks locals live across the back-edge, GPR locals stay put;
   only FP/SIMD caches flush).

## Anti-regression invariants (MUST hold; W54 lineage)

1. **Mutable-value correctness** — `local.set $i` updates local $i's register; every later `local.get $i` (until
   the next set) reads that register. The merge/branch correctness: at a control-flow join, a register-homed
   local holds its current value on ALL paths (it is a persistent home, not a transient vreg) — this is SIMPLER
   than Option A's merge-fence (no invalidation needed; the home persists). The Phase-II fixtures
   (write-then-read; loop-carried; multi-local) are the executable proof.
2. **GcRef slot-visibility (D-261/D-258)** — a reference-typed local in a register is invisible to the
   conservative GC scan (`scanNativeStackRoots`, native stack only). Today GC-on-JIT is unwired (D-258), so no
   live collection point exists in JIT code → register-homing a GcRef is currently safe. BUT the design MUST add
   the hook: at any GC-collection point (when D-258 lands), register-homed GcRef locals spill to their slots
   first (or are excluded from register-homing). For THIS rework: **GcRef locals stay slot-homed** (conservative;
   no perf regression vs today; revisit when D-258 + the GcRef adversarial test land). Non-ref locals get the win.
3. **Caller-saved discipline (ADR-0017 cohort)** — register-homed locals must not collide with the pinned runtime
   cohort (arm64 X19/X24-X28; x86_64 R15) and must be saved/restored across calls like any caller-saved value.
4. **Both-backends-equal (P7)** — arm64 + x86_64 get the same model; 3-host verify (D-262 cross-compile≠cross-run).

## Staged migration (Phase IV; full test net + Phase-II fixtures green at EVERY commit)

Big change → stage to keep each commit green + measurable:
1. **GPR locals, no-call straight-line loops** (the w45_addi case): reserve K GPR registers, prologue-load,
   local.get/set as reg refs, slot-overflow for the rest. Measure w45_addi. (Spike validates this first.)
2. **Call-site spill/reload** of caller-saved register-homed locals (realworld fixtures with calls).
3. **FP/v128 register-homed locals** (the fp class, V16-V28) — same model; re-measures the v128 loop.
4. **x86_64 parity** of all the above (P7); ubuntu test-all each step.
Each stage is `architectural`/`emit`-typed; the 3-cycle cap forces a step-back to spike if a stage drifts.

## Exit criterion

w45_addi **2.3× → ≤1.1× vs v1** AND full test net (spec 100% + edge_cases incl. the 3 Phase-II fixtures +
realworld + differential) green on 3 hosts. Phase V: ADR-0149/0150 Revision note (the regalloc headroom is real
on loop-locals) + ADR-0151 W45 re-examination (loop-persistence DOES matter for scalar locals).

## Validation spike (before on-branch impl, per ADR-0153 + spike_discipline)

`private/spikes/register-homed-locals/`: implement stage 1 (GPR locals register-homed for the no-call case) on a
throwaway branch/copy; run the 3 Phase-II fixtures (MUST stay green = correctness) + w45_addi (MUST approach v1 =
ROI ≤1.1×). Resolves the open design choice (local-register pre-reservation vs multi-def vreg). Green + ROI → land
stage 1 on-branch per the migration. Broken/thin → revise here before any on-branch code.

## Rejected alternatives

- **ADR-0154 Option A (value-reuse cache)** — recovers only ~17% (in-body redundant reads); the loop-top reload
  dominates. Superseded.
- **Defer past v0.1.0** — contradicts §1.2 + the design priority (ADR-0153).
- **A general optimising/SSA tier** — permanently out of scope (§3.2); this stays single-pass baseline (P3/P6).

## Consequences

- Closes the D-265 parity gap within P3/P6. The single biggest codegen change of Phase 15; staged + spiked +
  guarded by the Phase-II net to keep it safe (the campaign discipline, ADR-0153).
- Revises ADR-0149/0150 (regalloc headroom real on loop-locals) + re-opens ADR-0151 W45 (loop-persistence matters
  for scalar locals, not just v128) — both get Revision notes at Phase V.
- GcRef locals stay slot-homed for now (no regression); the register-homed-GcRef + GC-collection-point spill is a
  follow-on when D-258 (JIT GC trigger) + the D-261 adversarial test land.
