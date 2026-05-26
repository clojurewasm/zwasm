# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `6fb4d743` — **EH cycle stabilised end-to-end on
  Mac aarch64 + Linux x86_64 SysV**. Single-frame + cross-frame
  + 2-level cross-frame + payload propagation + multi-catch all
  green on both arches. 6 e2e JIT regressions + 1 interp
  safepoint-free invariant + dispatcher unit tests + D-183
  contract pin (`toModuleRelativePc` multi-function module-
  relative output). PC consolidation refactor (`c54ea0d5`).
- **10.D = CLOSED 2026-05-25**; **10.M (incl D-181 ungate),
  10.R 1..5, 10.TC-1, 10.G-i31-ops/2/3, 10.E** (IT-1..IT-6 +
  10.E-N-1..N-3 + 10.E-5b/5c + 10.E-payload-prop bundle +
  D-183/D-184 cross-frame fixes): SHIPPED.
- Closed this session: D-181 (memory64 x86_64), D-182 (catch
  landing pad load+push), D-183 (cross-frame Mac aarch64),
  D-184 (cross-frame x86_64 via sniffed loadFrame).
- **D-180 structural defenses STILL IN PLACE** (`2808bc81` +
  `a98c7b1f`): x86_64 `usesRuntimePtr` whitelist drift detector
  + test discipline §4 + paired lesson.

## ROADMAP §10 progress

- DONE (8/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D /
  10.E (full codegen + interp + cross-frame + cross-arch).
- IN-PROGRESS (3): 10.M (D-181 closed; realworld toolchain-
  blocked) / 10.R (5/5; gated on 10.G) / 10.TC.
- Pending (2): 10.G / 10.P (close gate).

## Next candidates (names + Refs; no predictions)

- **10.TC codegen** — return_call / return_call_indirect /
  return_call_ref JIT emit + frame_teardown helper (ADR-0112,
  ADR-0113 §A foundations shipped pre-bundle). Multi-cycle
  bundle.
- **10.E exnref / catch_ref / catch_all_ref** — v0.2 scope per
  ADR-0120 §3.
- **10.E spec corpus wiring** — 76 assertion fixtures from the
  Wasm 3.0 EH proposal. Smoke-baked at 10.T-2a; runner-side
  wiring open. spec_assert_runner_wasm_3_0.zig is currently a
  skeleton (130-line enumerate-and-count).
- **10.E × TC cross fixture** (`return_call_in_try_table.wat`)
  — depends on 10.TC codegen landing.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).
- **eh_frequency_runner impl** — currently a skeleton (`test/
  runners/eh_frequency_runner.zig`); the throw_rate × catch_depth
  matrix would validate the "EH bears zero cost on the non-
  throwing fast path" invariant from ADR-0114.

## Session highlights (2026-05-28; for handoff context)

24 commits across this session focused on Phase 10.E EH on JIT:
- ADR-0120 (Proposed) — JIT payload-marshalling design.
- 10.E-payload-prop bundle (5 cycles) — Runtime/JitRuntime
  fields + EmitCtx threading + throw.emit pop-N+store-N +
  per-clause landing-pad prelude. Closed at `bc486030`.
- D-183 + D-184 cross-frame discharge — module-relative PC
  normalisation + DWARF ret_addr-1 + CodeMap-aware sniffed
  loadFrame.
- 3 lessons: per-clause prelude pattern, x86_64 prologue/RBP/R15
  inversion, EH catch landing pad design.

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted
  (impl fully shipped + 6 e2e regressions; user flip is purely
  formal at this point).
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0017, ADR-0026, ADR-0111, ADR-0114 D1/D5/D6, ADR-0119,
  **ADR-0120** (this session's load-bearing decision).
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md`.
- Lessons (Phase 10 EH cycle):
  - `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  - `2026-05-28-eh-test-wrapper-host-fp-walk-segv.md`
  - `2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`
  - `2026-05-28-eh-catch-landing-pad-per-clause-prelude.md`
  - `2026-05-28-x86_64-prologue-rbp-r15-unwinder-mismatch.md`
