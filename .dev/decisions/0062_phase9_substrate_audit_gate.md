# 0062 — Insert Phase 9 → Phase 10 substrate re-examination gate

- **Status**: Accepted
- **Date**: 2026-05-16
- **Author**: Shota Kudo + Claude
- **Tags**: roadmap, governance, substrate, dispatch-table, P14, build-flags

## Context

The autonomous `/continue` loop has driven Phase 9 through ~47
sub-chunks under §9.9 / 9.9-l-1b-d093-d**. The chunks each move
"+ N PASS, 0 FAIL" forward against the Wasm 2.0 spec corpus on
two hosts. The mechanism that makes each chunk land is direct
editing of `switch (op)` arms in `src/ir/lower.zig` /
`src/validate/validator.zig` / `src/engine/codegen/arm64/emit.zig`
/ `src/engine/codegen/x86_64/emit.zig`, plus point fixes in the
spec_assert harness.

This is **at odds** with ROADMAP §4.5 (Feature modules and
dispatch-table registration / A12) and §4.6 (build flags
`-Dwasm=1.0|2.0|3.0` and `-Denable=<feature>`), which prescribe:

- Per-op handlers registered into a central `DispatchTable` from
  `src/instruction/wasm_X_Y/<category>.zig` (stateless families)
  or `src/feature/<X>/register.zig` (state-heavy capabilities);
- Frontend / interp / JIT consult the table without **any**
  feature-flag branching (P14);
- Build flags select which `register` modules compile in;
  disabled features simply don't populate the table.

The implementation drift is concrete:

1. `WasmLevel = enum { v1_0, v2_0, v3_0 }` is parsed by
   `build.zig:21` and threaded into `build_options.wasm_level`,
   but the only consumer is the CLI's `--version` printout
   (`src/cli/main.zig:119`). There is **no gating**.
2. `src/ir/dispatch_table.zig` defines `DispatchTable` with four
   `[N_OPS]?Fn` axes (parsers / interp / jit_arm64 / jit_x86),
   `init()` returning all-null. **No call site populates it**;
   no `registerAll(*DispatchTable)` exists.
3. `src/feature/{tail_call,memory64,simd_128,exception_handling,
   gc,function_references}/register.zig` are all `pub fn
   register(_: *DispatchTable) void {}` — no-op stubs.
   `src/feature/mvp/mod.zig` has the only non-trivial body
   (also unused — `mvp.register` is never called).
4. `src/instruction/wasm_X_Y/<cat>.zig` files exist with
   `register` bodies that DO assign function pointers, but
   nothing calls them; the assignments are dead writes.
5. The real op→handler binding is in giant exhaustive `switch
   (ZirOp)` blocks (~500 arms across the four primary files),
   edited per-chunk during Phase 9 expansion.

If Phase 9 closes (Wasm 2.0 100% PASS) without addressing this,
Phase 10 inherits:

- A 500-arm switch population that grows with every Wasm 3.0
  proposal (~20-50 new ops per: GC, EH, tail-call, memory64).
  Each new op needs ≥ 4 file edits to ≥ 4 switch arms.
- A `-Dwasm=` flag that the user can set but that has no
  observable effect on the binary, contradicting documented
  build behaviour.
- Documented design (§4.5 / §4.6) that diverges from the
  implementation, eroding the ROADMAP's authority as the
  single source of truth (P10).
- A latent risk of the v1 W54-class anti-pattern: per-feature
  branches scattered across the pipeline. ROADMAP §14
  "forbidden patterns" — "Pervasive build-time if-branching" —
  is at risk of normalised violation.

The project values (stated in this thread): **構造的にきれい /
高速 / 小さい / 教科書的 / 実用的**. The current trajectory
optimises for short-term spec PASS count and risks long-term
substrate erosion.

## Decision

Insert a new hard-gate row **between Phase 9 final close and
Phase 10 open** in ROADMAP §9: a substrate re-examination gate
that is structurally unavoidable. The autonomous loop's
existing hard-gate detector (`/continue` SKILL.md §"Exception —
hard human-in-loop transition gates", + the row's `🔒` +
gate-doc reference) fires it without further plumbing.

Concretely:

1. **Add ROADMAP §9.9 task row 9.12 (new)** —
   `🔒 Phase 9 完備 substrate re-examination (.dev/phase9_
   completion_substrate_audit.md) collaborative review`.
   Insert **before** the existing Phase 10 entry gate (which
   renumbers from 9.12 to 9.13).
2. **Create `.dev/phase9_completion_substrate_audit.md`** as the
   gate document. It frames the audit's scope (§4.5 / §4.6
   implementation review, P14 sharpening, P13 reconsideration,
   dispatch architecture spike comparison, gating mechanism
   choice) and lists the deliverables required to clear the
   gate (ADR-grade artefacts, optionally amendments to
   ROADMAP §2 / §4 / §14, optionally new ADRs supersede
   ADR-0023 §4.5 sub-claims, etc.). Captures the four open
   questions from the 2026-05-16 design discussion.
3. **The substrate audit takes precedence over Phase 10 entry
   prep** (existing 9.13 row, was 9.12). Reason: the audit may
   modify Phase 10's scope; sequencing audit-first prevents
   wasted Phase 10 prep work.

The autonomous loop continues to drive Phase 9 chunks (current
trajectory: D-122/D-125 → table_grow runtime callout → enable
remaining table_* / bulk / memory_init / wasi-host-import
families → 100% PASS). When 9.9 flips `[x]`, audit_scaffolding
fires (9.11), then the loop reaches row 9.12 (new substrate
audit gate) — `🔒` + gate-doc reference triggers the hard-gate
detector → autonomy stops → user-led design review opens. The
existing Phase 10 entry gate (now 9.13) opens only after the
substrate audit clears.

## Alternatives considered

### Alternative A — Fold the substrate audit into the existing Phase 10 entry gate (9.12)

- **Sketch**: Extend `.dev/phase10_transition_gate.md` with a
  new top-level section "Substrate audit". The review covers
  both Track D / Phase 10 entry AND substrate redesign in one
  session.
- **Why rejected**: (1) The two reviews have different scopes
  and ideal outcomes — Track D is about implementation
  capacity for Wasm 3.0 features; substrate audit is about
  whether ROADMAP §4.5 / §4.6 are themselves correct. Mixing
  them risks the substrate question being de-prioritised
  under Phase 10 implementation pressure. (2) The substrate
  audit's outcome may modify Phase 10 scope; sequencing
  audit-first is more robust.

### Alternative B — Do nothing; address substrate drift in Phase 10 organically

- **Sketch**: Continue Phase 9 → Phase 10 sequence. Address
  substrate as needed during Phase 10's first sub-chunks
  (instance-aware refactor) which already touch the same
  files.
- **Why rejected**: Phase 10's instance-aware refactor is its
  own ADR-grade work (per ROADMAP §9.10 → Phase 11 move
  history). Layering "instance-aware refactor + substrate
  redesign + Wasm 3.0 feature surface" into one Phase
  recapitulates the "everything-at-once" failure mode that
  P15 / P16 ("disciplined phase boundaries") was designed
  against.

### Alternative C — Address substrate inside Phase 9 itself (file the gate row inline at d-48)

- **Sketch**: Pause the d-48+ "enable remaining names" trajectory
  and start the substrate refactor immediately, as the next
  sub-chunk under §9.9.
- **Why rejected**: User directive (2026-05-16) is explicit:
  "今の方向性で一旦100%を目指す = Phase 9でOK." Phase 9 PASS
  count completion is treated as a deliverable in its own
  right; substrate re-examination follows the 100% achievement
  in a structurally-separate phase boundary.

## Consequences

### Positive

- Substrate audit is **structurally unavoidable**: the loop
  cannot bypass it. The `/continue` skill's hard-gate detector
  is already implemented and tested (Phase 7 → 8 gate, Phase
  9.12 Track D gate).
- Phase 9 completion semantics stay simple: 100% PASS → 9.9
  `[x]` → audit fires.
- The audit's deliverables (potentially ADRs amending §4.5
  / §4.6 / P13 / P14, possibly new dispatch architecture ADR,
  possibly Phase 10 scope amendment) land before any Phase 10
  implementation work, eliminating the chance of redo.
- ROADMAP's authority is preserved: when the audit finishes,
  either the implementation will catch up to §4.5 / §4.6 OR
  §4.5 / §4.6 will be amended to match the chosen direction.
  The drift is closed either way.

### Negative

- One extra hard gate before Phase 10. Project wall-clock to
  Phase 10 work increases by the audit duration.
- The audit may invalidate ADR-0023 §4.5 sub-claims and force
  cascading amendments. This is the cost of fixing the drift;
  doing it later costs more.

### Forbidden / out of scope

- The audit gate is **not** a deferral — its scope is to make
  the decision, not implement the result. The implementation
  (if any: e.g. dispatch-table completion, or comptime-switch
  generation, or per-op-file inline-switch macros) lands in
  Phase 10 sub-rows under whatever architecture is chosen.
- The audit does **not** revisit ADR-0017 (X19 runtime_ptr
  save), ADR-0023 zone layering (§4.1), ADR-0027 allocatable
  GPR pool, or other load-bearing JIT invariants. Scope is
  the **op-dispatch substrate** (§4.5 + §4.6) only, plus the
  P14 sharpening question that surfaces from it.

## Rollout

1. This ADR lands first (per ROADMAP §18.2: ADR before edit).
2. Same chunk: insert new row 9.12 into ROADMAP §9.9 task
   table; renumber existing 9.12 → 9.13; create
   `.dev/phase9_completion_substrate_audit.md`.
3. `/continue` skill's hard-gate detection rule (already
   generic per SKILL.md "Detection rule") picks up the new
   `🔒` + gate-doc-reference row at the next resume after 9.9
   flips. No skill-doc edit needed.
4. Phase 9 continues normally toward 9.9 `[x]`.

## References

- ROADMAP §2 P14 (forbidden: pervasive build-time if-branching).
- ROADMAP §4.5 (Feature modules and dispatch-table registration).
- ROADMAP §4.6 (Build flags — coarse and orthogonal).
- ROADMAP §9.12 (existing Phase 10 entry gate row).
- ROADMAP §18 (Amendment policy).
- `.claude/skills/continue/SKILL.md` §"Exception — hard
  human-in-loop transition gates" (the trigger mechanism).
- `.dev/phase10_transition_gate.md` (precedent gate doc).
- `.dev/archive/phase_gates/phase8_transition_gate.md` (precedent gate doc; archived 2026-05-19 in §9.12-A).
- 2026-05-16 chat discussion (substrate drift surfaced; user
  directive on sequencing).
