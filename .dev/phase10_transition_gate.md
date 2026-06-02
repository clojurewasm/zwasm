# Phase 9 → Phase 10 transition gate

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

> **Hard human-in-loop gate** before §9.12-equivalent flip /
> Phase 10 opens. The autonomous `/continue` loop **must stop**
> when it reaches this gate and surface to the user; no
> `ScheduleWakeup` fires until the gate checklist below is
> collaboratively cleared.
>
> Anchored from ROADMAP §9 Phase Status widget (Phase 10 row
> carries `🔒`) and from
> `.claude/skills/continue/SKILL.md` §"Exception — hard
> human-in-loop transition gates" carve-out for Phase 9 → 10.
>
> **DECIDED 2026-05-12** — all 5 open questions resolved per
> §9 decision record. Gate-doc framework finalised; per-section
> ☑ marking happens during Phase 9 close work and the per-
> subsystem ADR landings in Phase 10 prep.

## Why this gate exists

Phase 10 lands the Wasm 3.0 feature surface — **4 substantial
new subsystems** (WasmGC, Exception Handling, Tail Call,
memory64) — each of which:

1. Requires its own design ADR (validator extension scope, IR
   ZirOp dispatch shape, per-arch emit strategy, trap/landing-
   pad ABI, GC root scanning protocol).
2. Touches load-bearing data shapes (`Value` extern union
   extensions, `bounds_fixups` per-tag exception payloads,
   tail-call frame collapse, 64-bit memory offset plumbing).
3. Could conflict with adjacent subsystems if scoped in
   isolation (e.g. GC root scan needs cooperation from tail-
   call's frame-collapse semantics; EH stack unwinding needs
   to know about GC-managed locals).

Phase 9 (SIMD-128) was a single subsystem with well-defined
prior art (wasmtime / v8 SSE4.1 baseline). Phase 10 is 4
subsystems with sparser prior art and tighter cross-
dependencies. Opening it without **deliberate-skepticism
sequencing** risks the W54-class compounding-deferral failure
mode v1 hit with regalloc post-hoc layered optimisation.

The gate is intentionally **collaborative** — the autonomous
loop produces evidence (`audit_scaffolding`, debt walk, code
state inventory) but the **per-subsystem scope decisions**
require human-in-loop strategic judgment.

## Checklist (must all be ☑ before Phase 10 opens)

### 1. Phase 9 functional completion

- [ ] `zig build test-all` green on Mac + ubuntunote + windowsmini
      (3-host per ADR-0067 ubuntunote pivot; OrbStack retired);
      latest pushed commit. Phase boundary reconciliation per
      ADR-0049 — windowsmini deferred per-chunk
      but **required at this gate**.
- [ ] §9.9 spec gate: `simd_assert_runner: N passed, 0 failed,
      M skipped (= 0 skip-impl + M skip-adr)` on all 3 hosts.
      The `skip-impl = 0` clause is per ADR-0029 (Track C Path B
      chunks 9.9-h-21..-24 must have closed first; if they
      haven't, this gate cannot fire).
- [ ] §9.10 disposition recorded — Track A Option (3) chose
      "move to Phase 11"; ROADMAP row `[~]` marker landed; Phase
      11 row prose absorbed the per-op-gap-analysis work;
      ADR-0043 amendment landed. **Verify**: `grep -n "9.10"
      .dev/ROADMAP.md` shows the `[~] moved to Phase 11` marker.
- [ ] §9.11 audit pass landed (`audit_scaffolding` skill
      Phase-boundary run; `private/audit-YYYY-MM-DD-phase9-
      close.md` exists; 0 `block` findings on §F / §G).
- [ ] §9.11 SHA backfill landed (§9.9 `[x]` rows have
      Status-column SHAs filled per the canonical backfill
      pattern).
- [ ] Bench Phase 9 close baseline appended to
      `bench/results/history.yaml` per ADR-0012 §7 cadence
      (= zero-point for any Phase 10 measurement).

### 2. Phase 10 prep-cycle deferred-work closure

The Phase 10 prep mode (2026-05-11 .. 2026-05-12) produced
4 deliverables and 2 new debt rows. Verify all are properly
landed:

- [ ] Track A (§9.10 → Phase 11) — **implementation chunk
      landed**: `git log --grep="track A"` shows the 1-chunk
      ROADMAP + ADR-0043 amend + D-074/D-076 update commit.
- [ ] Track B (source split D-057 / D-065) — **6 chunks
      landed** (9.9-h-15..-20). Verify: 5 files under
      §A2 hard cap (`bash scripts/file_size_check.sh --gate`
      exit 0; **gate flipped from warn-only to hard-fail**).
      D-057 + D-065 deleted from `.dev/debt.yaml`.
- [ ] Track B follow-up — new debt **D-081** filed
      (legacy `emit_test_int/float.zig` rename when emit.zig
      source-splits; bundled with D-052 discharge).
- [ ] Track C (ADR-0029 Path B) — **4 chunks landed**
      (9.9-h-21..-24). Verify: `grep -rn "skip-impl\|skip-adr-"
      test/spec/` returns matches (vocab migrated); D-073
      deleted from `.dev/debt.yaml`; D-072 status updated to
      "(a/b)-path closed; (c)-path → D-082".
- [ ] Track C follow-up — new debt **D-082** filed (D-072
      (c)-path: 4 embenchen fixtures → Phase 11 / 1 externref
      fixture → Phase 11 default-or-Phase 10 if GC reftype
      work surfaces it).
- [ ] Track C gate addition — `scripts/check_skip_adrs.sh`
      wired as `.githooks/pre-commit` gate; coherence checks
      pass.
- [ ] Track D (this file) — gate doc landed and §9.12-equiv
      ROADMAP row references it (see §6 below).

### 3. Per-subsystem entry checklist (the 4 Wasm 3.0 subsystems)

Phase 10's 4 subsystems each need design groundwork **before**
implementation chunks land. The autonomous loop's first
mistake would be to start a "first chunk" without a design
ADR. This section gates ADR landing per subsystem.

#### 3a. WasmGC

- [ ] Design ADR landed: `.dev/decisions/NNNN_wasmgc_design.md`
      covering: `Value` extern union extensions (`ref T` →
      tagged pointer scheme per ROADMAP §4.10 lines 884–894),
      heap allocator (`mark_sweep.zig`) integration, GC root
      scan protocol (stack + globals enumeration), barrier
      strategy (write barrier for sub-typed ref writes).
- [ ] ZIR ZirOp catalogue confirmed: `zir.zig` already has
      `struct.new` / `array.new` / `ref.test` / `ref.cast` /
      `i31.*` opcode space carved out (lines 577–611). Verify
      no further opcodes needed for the Wasm 3.0 GC spec at
      the version we're targeting.
- [ ] Validator extension scoped: `validate/validator.zig`
      handler functions for the GC opcodes named; sub-typing
      lattice rules drafted.
- [ ] Per-arch emit strategy sketched:
      `src/engine/codegen/{x86_64,arm64}/op_gc.zig` files
      created as orchestrator stubs; recipe families enumerated
      (struct field access = load + tag-check; array
      bounds-check = existing bounds_fixups pattern reused).
- [ ] Spec proposal version pinned: Wasm 3.0 GC at spec phase
      X.Y (cite the W3C WebAssembly/proposals/gc commit ID or
      release tag at this gate; `.dev/proposal_watch.md`
      updated).
- [ ] **D-082 sub-row (b) re-evaluated**: externref segment
      fixture — does this GC design pass surface a fix? If
      yes, retire `skip_externref_segment.md` in the same
      design ADR's first impl chunk and update D-082.

#### 3b. Exception Handling (EH)

- [ ] Design ADR landed: `.dev/decisions/NNNN_eh_design.md`
      covering: try-table / throw / throw_ref opcodes; per-tag
      exception payload shape (extends `bounds_fixups` per
      Phase 8 gate §3 confirmation); landing-pad ABI (frame
      unwinding sequence; integration with regalloc spill
      restoration); panic-vs-throw distinction (Wasm trap !=
      Wasm exception).
- [ ] ZIR ZirOp catalogue confirmed: `try_table` + `throw` +
      `throw_ref` exist in `zir.zig:561-568`. Verify variant
      coverage matches the Wasm 3.0 EH proposal version.
- [ ] Validator extension scoped: try-table label-class
      resolution + tag-type checking.
- [ ] Per-arch emit strategy: landing pad emission shape
      sketched; cooperation with prologue/epilogue / regalloc
      spill restoration documented.
- [ ] Spec proposal version pinned (cite W3C proposals/exception-
      handling commit ID).
- [ ] **Cooperation with GC**: design ADR documents how GC root
      scanning interacts with in-flight exception state
      (stack-walking the unwound frames must enumerate
      GC roots consistently).

#### 3c. Tail Call

- [ ] Design ADR landed: `.dev/decisions/NNNN_tail_call_design.md`
      covering: return_call / return_call_indirect /
      return_call_ref opcodes; frame collapse semantics
      (caller's frame replaced before callee body executes);
      regalloc consequence (caller's locals/spills lifetime
      ends at the tail-call; new caller-save invariants).
- [ ] ZIR ZirOp catalogue confirmed: `return_call` +
      `return_call_indirect` + `return_call_ref` exist in
      `zir.zig:567-569`.
- [ ] Validator extension scoped: tail-call call-stack lint
      (caller's signature must match callee's result; no
      operands left on operand stack).
- [ ] Per-arch emit strategy: frame-collapse sequence per arch
      (ARM64: restore FP/LR, set SP = caller-of-caller's SP,
      branch to callee; x86_64: restore RBP, RSP adjust, jmp
      to callee with calling convention preserved).
- [ ] Spec proposal version pinned.
- [ ] **Cooperation with EH**: design ADR documents whether
      tail-call across a try-frame is allowed / disallowed
      (Wasm 3.0 spec position cited).

#### 3d. memory64

- [ ] Design ADR landed:
      `.dev/decisions/NNNN_memory64_design.md` covering: the
      `memarg` 64-bit offset flag; address-mode emission with
      64-bit displacement (ARM64: LDR/STR with 64-bit offset
      via scratch reg; x86_64: 64-bit displacement via address-
      mode prefix); bounds-check shape adjustment (current
      bounds_fixups assumes 32-bit memory offset; needs widening).
- [ ] ZIR ZirOp catalogue confirmed: ROADMAP §4 line 476 notes
      "memory64 — uses the same load/store ops with a memarg
      flag". Verify the flag plumbing is ready in `parse/
      sections.zig` + `validator.zig`.
- [ ] Validator extension scoped: 64-bit-memory module-level
      flag detection; bounds-check sizing.
- [ ] Per-arch emit strategy: 64-bit displacement emission
      patterns sketched; impact on existing 32-bit fast path
      (no regression for default 32-bit memory modules).
- [ ] **D-079 (ii) discharge plan**: v128 cross-module imports
      gating named "Phase 10+ import-aware chunk schedule" —
      memory64 work touches the same `Runtime.globals: []*Value`
      pointer-per-entry layer (per ADR-0052 §3). Verify
      whether the memory64 chunks naturally close D-079 (ii)
      or whether they trigger an unrelated cross-module import
      path that bypasses it.
- [ ] Spec proposal version pinned.

### 4. Design cleanliness extrapolation

Phase 10's 4 subsystems must not violate:

- [ ] **Zone architecture** (ADR-0023): `bash scripts/zone_check.sh
      --gate` exit 0 at Phase 10 entry. No layering violation
      introduced by GC subsystem's heap-manager calls into
      runtime, EH's stack-walker calls into engine, etc.
- [ ] **Single allocator** (`Runtime` single-allocator per
      ADR-0014 §6.K.2): GC heap allocator integrates with the
      `Runtime` allocator hierarchy without introducing a
      parallel allocator chain.
- [ ] **§14 forbidden list compliance**: each subsystem's
      design ADR self-checks for "Single field serving two
      distinct semantic axes" anti-pattern (ROADMAP §14;
      `.claude/rules/single_slot_dual_meaning.md`).
      Specifically: GC's tagged pointer scheme; EH's
      bounds_fixups extension; Tail Call's frame-collapse
      indicator.
- [ ] **AOT compatibility** (Phase 12 horizon): every Phase 10
      subsystem's emit output is consumable by AOT serialise.
      No JIT-only shortcut (e.g. immediate patching) in
      hot paths that AOT can't replay.
- [ ] **No copy-paste from v1** (ROADMAP P10): v1's GC / EH /
      tail-call / memory64 implementations may be read for
      survey (Step 0); v2 re-derives.

#### 4a. Phase 10 → Phase 11 deferred-work dependency DAG

Phase 10 close leaves Phase 11 (WASI 0.1 full + bench infra)
to absorb several items already routed there by the Phase 10
prep cycle:

```
    ┌──────────────────────────────────────────────────┐
    │ Phase 10 prep cycle deferrals (Tracks A + C)     │
    └────────────────────────────────┬─────────────────┘
                                     │
            ┌────────────────────────┴──────────┐
            │                                    │
    ┌───────▼─────────────────┐    ┌────────────▼───────────────┐
    │ §9.10 → Phase 11        │    │ D-082 (D-072 (c)-path)     │
    │ (Track A Option 3)      │    │  ├─ (a) 4 embenchen        │
    │ SIMD per-op gap         │    │  │   fixtures (Phase 11)   │
    │ analysis vs (wasmtime,  │    │  └─ (b) 1 externref        │
    │ wazero, wasmer) +       │    │      fixture (Phase 11     │
    │ Phase 15 debt filing    │    │      default OR Phase 10   │
    │ + 3× threshold + D122   │    │      if GC reftype work    │
    │                          │    │      surfaces it)         │
    └───────────┬─────────────┘    └────────────────────────────┘
                │
                │ (D-074's "Phase 11 natural carrier"
                │  alignment;  bench infra cohort)
                │
    ┌───────────▼──────────────────────────────────────┐
    │ Phase 11 bench infra cohort (D-074 discharge):   │
    │  - `-Dwith-bench-compare` build flag             │
    │  - wazero/wasmer in flake.nix                     │
    │  - SIMD per-op micro-bench corpus                 │
    │  - gap-analysis script                            │
    │  - Phase 15 debt-entry filing convention          │
    └───────────────────────────────────────────────────┘
```

**Sequencing constraint** for Phase 11 entry: the bench infra
cohort + the §9.10 SIMD per-op work form a single Phase 11
opening pass (~ 6-8 chunks). D-082 sub-row (a) lands alongside.
D-082 sub-row (b) re-walks barrier on every resume per
`/continue` Step 0.5.

#### 4b. Cross-subsystem cooperation matrix

The 4 Wasm 3.0 subsystems interact non-trivially. Confirm each
cell has a documented design choice:

| Pair                 | Interaction                                                                 | Where documented |
|----------------------|-----------------------------------------------------------------------------|------------------|
| GC × EH              | Stack unwinding must enumerate GC roots consistently                        | §3a / §3b ADRs   |
| GC × Tail Call       | Frame collapse must preserve GC root reachability before callee runs        | §3a / §3c ADRs   |
| GC × memory64        | 64-bit memory's bounds-check shape must not interfere with GC barrier emission | §3a / §3d ADRs |
| EH × Tail Call       | Tail-call across try-frame: allowed/disallowed (spec position)              | §3b / §3c ADRs   |
| EH × memory64        | Exception payloads referencing 64-bit memory regions                        | §3b / §3d ADRs   |
| Tail Call × memory64 | Frame-collapse interaction with 64-bit memory pointers in locals/spills     | §3c / §3d ADRs   |

### 5. Strategic review (collaborative, human-in-loop)

The only checklist item the autonomous loop cannot self-
resolve.

- [ ] Re-read ROADMAP §1 (mission) and §2 (P/A) — does Phase
      10 entry match what they promised?
- [ ] **`meta_audit` skill invocation** — deliberate-skepticism
      pass against ROADMAP §1/§2/§9/§14/§15 and recent ADRs
      (especially Phase 9 ADRs: ADR-0041 / 0049 / 0051 / 0052
      / 0053 / 0054 / 0055-and-up if Track A/C ADRs landed
      with their own numbers). Output:
      `.dev/meta_audits/YYYY-MM-DD-phase10-entry.md`.
- [ ] Phase 10 scope confirmation: is "Wasm 3.0 feature-
      complete" still the right framing? (Alternative
      considerations: split GC out to its own Phase 10a;
      merge memory64 with Phase 14 thread/memory64 cohort;
      include "function references" proposal which is Wasm
      3.0-adjacent.)
- [ ] Subsystem ordering decision: which subsystem opens
      first (GC vs EH vs Tail Call vs memory64)? Default:
      memory64 (smallest design surface, lights up existing
      load/store ops with a flag); then Tail Call (regalloc-
      coupled but bounded); then EH (cross-cuts unwind +
      regalloc spill restoration); then GC (the largest
      surface — heap manager + barriers + root scan).
- [ ] Adoption-trigger audit: are any `O-NNN` candidates in
      `.dev/optimisation_log.md` Phase-10-relevant (e.g.
      GC-allocation-fast-path candidates)?
- [ ] Decision log: open
      `.dev/decisions/NNNN_phase10_entry.md` ADR if any
      §1/§2/§4/§5/§9/§14 amendment results from this review.

## §6. ROADMAP wiring (load-bearing for hard-gate detector)

The `/continue` skill's hard-gate detector requires the
following:

1. Phase 10 row in §9 Phase Status widget carries `🔒` —
   ✅ already present (line 1175).
2. The §9 task table contains a row whose body references
   this gate doc file path AND `🔒`. Currently §9.12 reads
   "Open §9.10 inline + flip phase tracker" — that text is
   stale (§9.10 moved to Phase 11 per Track A Option 3) AND
   doesn't reference this gate doc. **Update §9.12 row** as
   part of the Track D implementation chunk:

   > | 9.12 | 🔒 Phase 10 entry gate review (`.dev/phase10_transition_gate.md` checklist all ☑). Hard human-in-loop; autonomous loop stops here. | [ ] |

3. The Track D implementation chunk lands this gate doc +
   §9.12 row update + `.claude/skills/continue/SKILL.md`
   "Currently registered hard gates" list extension (add
   "Phase 9 → 10 gate at §9.12" alongside the existing
   "Phase 7 → 8 gate at §9.7 / 7.13" entry).

## §7. Gate exit conditions

The `9.12` row in ROADMAP §9 flips to `[x]` **only when all
five sections above are ☑**. Until then:

- The autonomous `/continue` loop refuses to open Phase 10.
- `ScheduleWakeup` is not armed when the next-task lookup
  resolves to row `9.12` — instead, the loop surfaces to user
  with a one-sentence handoff: "Phase 10 entry gate
  (`.dev/phase10_transition_gate.md`) needs collaborative
  review; pausing autonomous mode."
- The user re-engages by working through the checklist
  sections, marking ☑ as items resolve, and finally asking
  for the gate to be cleared.

## §8. Why no ADR for this gate?

Same reasoning as `archive/phase_gates/phase8_transition_gate.md` §"Why no ADR
for this gate?": gate doc + ROADMAP row + SKILL.md carve-out
together define a **workflow regime**, not a §1/§2/§4/§5
design choice. ROADMAP §18.2 deviation watch lists the
§-numbers that require ADRs; "Phase boundary procedure" isn't
among them. A new row added inline in §9's task table is
precisely the "routine status update / expanding the phase
table" path §18 lets through without an ADR.

If a future cycle decides to **remove** this gate, that
decision **does** need an ADR — reversing a load-bearing
workflow rule.

## §9. Resolved questions

1. **Phase 10 scope**: maintain current ROADMAP framing — **4
   subsystems** (WasmGC + EH + Tail Call + memory64). No
   addition (function-references stays out per ROADMAP §1.2's
   "Wasm 3.0 完備" wording boundary) and no removal /
   sub-phase splitting.
2. **Subsystem ordering**: **memory64 → Tail Call → EH → GC**
   (small → large design surface). memory64 lights up existing
   load/store with a flag; Tail Call is regalloc-coupled but
   bounded; EH cross-cuts unwind + spill restoration; GC is
   the largest (heap manager + barriers + root scan).
3. **ADR numbering for Phase 10 design ADRs**:
   - Track A: **in-place amend ADR-0043** (no new ADR).
   - Track B: **new ADR-0054** (single ADR per Track B Q2=A).
   - Track C: **in-place amend ADR-0029** (no new ADR).
   - Track D: this gate doc (no ADR per §8).
   Phase 10 design ADRs start at **ADR-0055** (memory64 first
   per Q2 ordering) → ADR-0056 (Tail Call) → ADR-0057 (EH) →
   ADR-0058 (GC).
4. **D-082 sub-row (b) early-discharge**: **(α) flip-rule** —
   if Phase 10 GC chunks touch externref segment handling,
   fix in the same chunk and retire `skip_externref_
   segment.md`. Matches the no-drift principle (機会主義的
   前倒し). D-082 row body's sub-row (b) discharge trigger
   already documents this — `/continue` Step 0.5 barrier walk
   surfaces the early-discharge opportunity automatically.
5. **Gate doc granularity**: **(α) item-level granularity
   maintained** (Phase 8 gate mirror). 22 checkboxes total
   stays inline; per-subsystem design ADRs may carry their
   own deeper checklists referenced from §3a–§3d.

## §10. Decision record

| Date       | Decision                                                                                                                                       | Recorded by              |
|------------|------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------|
| 2026-05-12 | Initial gate doc landed (Phase 10 prep mode Track D deliverable); §3 + §4 framework drafted                                                    | autonomous loop          |
| 2026-05-12 | Q1=keep 4 subsystems, Q2=memory64→TailCall→EH→GC ordering, Q3=ADR-0055..0058 numbering, Q4=(α) flip-rule for D-082 (b), Q5=(α) item-granularity | user (prep mode session) |

## §11. References

- `.dev/archive/phase_gates/phase8_transition_gate.md` (template; structure mirrored)
- `.claude/skills/continue/SKILL.md` §"Exception — hard
  human-in-loop transition gates" (the carve-out this doc
  registers under)
- ROADMAP §9 Phase Status widget (line 1175), §9.10 (Track A
  disposition), §9.11 (audit + SHA backfill), §9.12 (this
  gate's ROADMAP anchor row — text update required)
- ROADMAP §4.10 (GC subsystem) + §4 ZIR catalogue (lines
  476–611 — Phase 10 opcode space already carved out)
- ADR-0023 §"feature/" directory structure (gc / exception_handling /
  tail_call / memory64 slots reserved)
- ADR-0014 §6.K (redesign / Value extern union foundation)
- ADR-0028 M3 (ring buffer; EH per-tag payload extension)
- ADR-0029 (skip semantics; Track C Path B reshapes for Phase
  10 skip-ADR workflow)
- ADR-0043 (SIMD perf eval scope; Track A reshapes for §9.10
  Phase 11 migration)
- ADR-0049 (windowsmini per-chunk deferral; Phase boundary
  reconciliation rule)
- ADR-0052 §3 (cross-module global import layer; D-079 (ii)
  blocker)
- ADR-0053 (spilled-V128 ABI; helper pub-ification template
  for Phase 10 cross-class primitives)
- `.dev/debt.yaml`: D-052 (prologue extract), D-074 (Phase 11
  bench infra), D-079 (ii) (v128 cross-module imports), D-081
  (emit_test rename; Track B follow-up), D-082 (D-072 (c)-
  path; Track C follow-up)
- `.dev/phase10_prep/track_{a,b,c}_*.md` (sibling Phase 10
  prep deliverables — decisions feeding this gate)
- `.dev/proposal_watch.md` (Wasm proposal version tracking;
  per-subsystem spec-phase pinning happens here)
