# Phase 7 → Phase 8 transition gate

> **Hard human-in-loop gate** before §9.8 opens. The autonomous
> `/continue` loop **must stop** when it reaches this gate and
> surface to the user; no `ScheduleWakeup` fires until the gate
> checklist below is collaboratively cleared.
>
> Anchored from ROADMAP §9.7 / 7.13 (the gate row) and from
> `.claude/skills/continue/SKILL.md` §"Phase boundary — inline,
> no stop" carve-out for Phase 7 → 8.

## Why this gate exists

v1 had multiple "interpreter was actually fast" surprises (W43 /
W44 / W45 hoist, coalescer, post-hoc liveness drift, D116
abandoned address-mode folding). Phase 8 in v2 is the JIT
optimisation foundation — the wrong starting baseline here
contaminates Phase 9 / 11 / 15 measurements for the rest of the
project. We want **a single deliberate-skepticism pause** to
confirm:

1. Phase 7 actually delivers a clean baseline (3-host green,
   realworld coverage, three-way differential 🔒).
2. Debt is honestly cleared, not parked.
3. The design still reads cleanly when extrapolated to AOT +
   Wasm 3.0 + WASI extensions + SIMD landing.
4. The optimisation candidate space is enumerated and triaged
   **before** we start adopting things, so we adopt on bench
   numbers — not gut feel.

The gate is intentionally **collaborative** — `audit_scaffolding`
is automatic and flags drift, but the strategic judgment ("is
this clean enough?") is human-in-loop.

## Checklist (must all be ☑ before §9.8 opens)

### 1. Phase 7 functional completion

- [ ] `zig build test-all` green on all three hosts (Mac
      aarch64 + OrbStack Ubuntu x86_64 + windowsmini), latest
      pushed commit.
- [ ] §9.7 / 7.5 spec gate: pass=fail=skip=0 via ARM64 JIT
      on Mac.
- [ ] §9.7 / 7.8 spec gate: pass=fail=skip=0 via x86_64 JIT
      on both Linux x86_64 + Windows x86_64.
- [ ] §9.7 / 7.9 + 7.10 realworld: ≥ 40/50 samples passing
      on both ARM64 and x86_64.
- [ ] §9.7 / 7.11 three-way differential 🔒 lock: 0 mismatch
      over spec + realworld on each host. **This is the
      load-bearing 🔒 of the project.**

### 2. Debt-ledger honest reconciliation

- [ ] Every `Status: now` row in `.dev/debt.md` discharged.
- [ ] Every `Status: blocked-by:` row whose named barrier was
      dissolved during Phase 7 flipped to `now` and discharged
      (or re-justified with current `Last reviewed`).
- [ ] No row's `Last reviewed` older than the start of Phase
      7 (= confirms no row was simply parked through the entire
      phase without re-evaluation).
- [ ] `audit_scaffolding §F` produces zero `block` findings on
      debt coherence.

### 3. Design cleanliness extrapolation

Phase 8 is followed by Phase 11 (AOT), Phase 14 (concurrency
+ thread support), Phase 15 (advanced JIT optimisation), and
proposal-driven Phases for Wasm 3.0 GC / EH / SIMD / WASI
preview2. The current shape must remain clean under that
horizon.

- [ ] **AOT**: `engine/codegen/aot/` slot exists (already
      reserved per ADR-0023). Confirm the JIT codegen layer
      doesn't entangle interpreter state — AOT must be able
      to consume the same ZIR+regalloc output without
      additional plumbing.
- [ ] **Wasm 3.0 GC** (proposal phase advance expected post
      Phase 8): `Value` extern union + `feature/gc/` slot
      reserved. Confirm `Value` shape doesn't need restructure
      to add `(ref T)` types.
- [ ] **Wasm EH** (proposal phase advance expected post Phase
      8): trap stub design (`bounds_fixups` → ADR-0028 M3 ring
      buffer) extends naturally to per-tag exception payloads.
- [ ] **WASI preview2**: `wasi/` subsystem can extend to
      `WasiP2Component` without breaking p1 (`preview1.zig`)
      consumers.
- [ ] **SIMD**: `feature/simd/` slot exists. `Value.v128`
      already lands in `extern union`. Confirm SIMD ops don't
      require ZIR opcode-space restructuring.
- [ ] Zone architecture (post-ADR-0023) has zero violations
      (`bash scripts/zone_check.sh --gate` exit 0).
- [ ] File-size soft caps: no Phase 7 file at > 2× soft-cap
      LOC (= unchecked monolith risk before Phase 8 opens).

#### 3a. Phase 7 → 8 deferred-work dependency DAG

Phase 7 closing leaves a stack of "Phase 8 follow-up" deferred
pieces whose **inter-dependency is implicit** across debt rows
and ADR References. Surface that dependency before §9.8 opens
so we can sequence Phase 8 work without false-start re-deletions.

Discovered during §9.7 / 7.5-spec-assertion-driver-{o,p,q}:

```
    ┌─────────────────────────────┐
    │ Class-aware regalloc        │ ← root of the DAG
    │ (per-class max_reg_slots,   │
    │  not the GPR-sized cap)     │
    └────────┬────────────────────┘
             │
             ├──► FP-class spill staging (V-class scratch +
             │    encLdrSImm/encStrSImm spill paths)
             │     │
             │     └──► op_alu_float / op_convert / bounds_check
             │          (17 sites today flagged by
             │           `scripts/spill_aware_check.sh`)
             │
             ├──► Wasm 2.0 multi-value blocks (D-035)
             │     │
             │     ├──► parser typeidx-blocktype path
             │     ├──► validator multi-result resolve
             │     └──► op_control.emitBlock multi-value merge
             │
             └──► x86_64 emit refactor (D-030: 9-module split,
                  + D-029 parallel-move) reuses ARM64's
                  spill-staging shape but only after
                  class-aware regalloc lands; otherwise the
                  same `max_reg_slots` mismatch trap fires
                  on x86_64 with 4-vs-8 register-pool sizing
                  (cross-module sync rule, per
                  `.dev/lessons/2026-05-06-regalloc-pool-size-mismatch.md`).
```

**Sequencing constraint**: each successor needs its predecessor
landed first; otherwise the same lessons re-pay. Specifically:

- [ ] `class-aware-regalloc` chunk landed (separate
      `max_reg_slots_gpr` / `max_reg_slots_fp`, OR per-call
      class parameter to `regalloc.compute`). Verifies the
      `chunk-q resolveFp shim` is replaced by a structural
      design, not a band-aid.
- [ ] `fp-spill-machinery` chunk landed (V-class scratch
      reservation + load/store S/D imm-form spill paths +
      `fpLoadSpilled` / `fpDefSpilled` / `fpStoreSpilled`
      helpers parallel to GPR equivalents). Verifies
      `spill_aware_check.sh` BASELINE drops to ≤ 5 (only
      the GPR-side leftovers in op_control / op_const).
- [ ] D-035 (Wasm 2.0 multi-value) landed. Verifies
      spec_assert corpus expansion to `block.wast` /
      `br_*.wast` / `call.wast` is no longer blocked.
- [ ] D-030 + D-029 (x86_64 split + parallel-move) landed
      OR explicitly deferred to Phase 8 with the deferral
      rationale recorded in this gate's "Strategic review"
      section.

The **why**: v1's W54 post-mortem proved that "we'll fix it
later" deferrals compound silently when the dependency
direction isn't published. Every deferred piece in this DAG
has at least one predecessor it cannot bypass — landing them
out of order means re-doing earlier work.

### 4. Optimisation log triage

- [ ] `.dev/optimisation_log.md` has `bench/results/history.yaml`
      datapoints recorded for Phase 7 close baseline (= zero
      point for every Phase 8 measurement).
- [ ] Every `O-NNN` candidate row reviewed: status moved to
      `Adopted` (with commit SHA) / `Rejected` (with lesson) /
      `Deferred` (with concrete trigger), or stays
      `Investigating` (max 3 row at this status — it's a
      bottleneck for Phase 8 actual work).
- [ ] Every `R-NNN` row's re-evaluation trigger re-checked:
      did any trigger fire during Phase 7? If yes, mirror to
      `O-NNN` `Investigating`.
- [ ] No `Adopted` row missing commit SHA. No `Deferred` row
      missing concrete trigger.

### 5. Strategic review (collaborative, human-in-loop)

This is the only checklist item the autonomous loop **cannot**
self-resolve. The user and assistant work through:

- [ ] Re-read ROADMAP §1 (project mission) and §2 (P/A
      principles). Does Phase 7's actual landing match what
      §1/§2 promised?
- [ ] **`meta_audit` skill invocation** — runs the periodic
      deliberate-skepticism pass against ROADMAP §1/§2/§9/§14/§15
      and recent ADRs. Surfaces drift. Output lands at
      `.dev/meta_audits/YYYY-MM-DD-phase7-close.md`.
- [ ] Phase 8 scope confirmation: is "JIT optimisation foundation"
      still the right framing? v1 surprises ("interpreter was
      fast") suggest non-JIT optimisations may belong here too —
      revisit §9.8 scope text in light of `.dev/optimisation_log.md`
      candidate distribution.
- [ ] Adoption-trigger audit: of the candidates moved to
      `Adopted` in step 4, are bench numbers actually present?
      If any was adopted on gut feel, demote to `Investigating`.
- [ ] Decision log: open `.dev/decisions/NNNN_phase7_close.md`
      ADR if any §1/§2/§4/§5/§9/§14 text needs amendment as a
      result of this review.

## Gate exit conditions

The `7.13` row in ROADMAP §9.7 flips to `[x]` **only when all
five sections above are ☑**. Until then:

- The autonomous `/continue` loop refuses to open §9.8.
- `ScheduleWakeup` is not armed when the next-task lookup
  resolves to "open §9.8" — instead, the loop surfaces to user
  with a one-sentence handoff: "Phase 8 entry gate
  (`.dev/phase8_transition_gate.md`) needs collaborative review;
  pausing autonomous mode."
- The user re-engages by working through the checklist sections,
  marking ☑ as items resolve, and finally asking for the gate
  to be cleared.

## Why no ADR for this gate?

This gate document + the `7.13` ROADMAP row + the SKILL.md
carve-out together define a **workflow regime**, not a §1/§2/§4/§5
design choice. ROADMAP §18.2 deviation watch lists the §-numbers
that require ADRs; "Phase boundary procedure" isn't among them.
A new row added inline in §9.7's task table is precisely the
"routine status update / expanding the phase table" path §18 lets
through without an ADR.

If a future cycle decides to **remove** this gate (= autonomous
Phase 8 opens), that decision **does** need an ADR — because it
reverses a load-bearing workflow rule. Removal is the gated
direction, not introduction.

## Future use

The same gate template should be reused at Phase 11 close (→
Phase 12+ horizon — release readiness, AOT shipping) and any
other place where a "deliberate skepticism pause" is desirable.
Replicate this file's structure under
`.dev/phase<N>_transition_gate.md` and add a corresponding
`<N>.gate` row to that phase's task list.
