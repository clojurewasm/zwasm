# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `bc486030` — **10.E-payload-prop bundle CLOSED**.
  EH throw-with-payload end-to-end on Mac aarch64 + Linux x86_64
  SysV. Tripwire test `runI32Export: throw + catch_ with i32
  payload returns 88` green (gated windows-only at the loop's
  ADR-0067 phase-boundary marker). Mac local + cross-compile
  x86_64-linux green; ubuntu verify pending Step 0.7.
- **10.D = CLOSED 2026-05-25**; **10.M (incl D-181 ungate),
  10.R 1..5, 10.TC-1, 10.G-i31-ops/2/3, 10.E** (IT-1..IT-6 +
  10.E-N-1..N-3 + 10.E-5b/5c + 10.E-payload-prop bundle):
  SHIPPED.
- **D-181 = CLOSED `f37977df`** — memory64 i64-idx on x86_64 SysV.
- **D-182 = CLOSED `bc486030`** — JIT catch landing pad load+push
  for N>0 tag params (per-clause prelude in arm64 + x86_64
  emit.zig; `.catch_ref` / `.catch_all_ref` exnref push remains
  v0.2 scope per ADR-0120 §3).
- **D-180 structural defenses SHIPPED** (`2808bc81` + `a98c7b1f`):
  x86_64 `usesRuntimePtr` whitelist drift detector + test
  discipline §4 + lesson.

## ROADMAP §10 progress

- DONE (8/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D /
  10.E (with payload-prop bundle close completing the codegen
  scope for caught exceptions with i32/i64 tag params).
- IN-PROGRESS (3): 10.M (D-181 closed; realworld toolchain-blocked) /
  10.R (5/5; gated on 10.G) / 10.TC.
- Pending (2): 10.G / 10.P (close gate).

## Next candidates (names + Refs)

- **10.TC codegen** — return_call / return_call_indirect /
  return_call_ref JIT emit + frame_teardown helper (ADR-0112,
  ADR-0113 §A foundations shipped pre-bundle). Likely
  multi-cycle codegen bundle.
- **10.E exnref / catch_ref / catch_all_ref** — v0.2 scope per
  ADR-0120 §3, but partial impl could ship for arm64-only as
  follow-on to D-182.
- **10.E spec corpus wiring** — 76 assertion fixtures from the
  Wasm 3.0 EH proposal (per ROADMAP row 10.E). Smoke-baked at
  10.T-2a; runner-side wiring + per-directive PASS/SKIP/SKIP-ADR
  accounting open.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted (the
  bundle's design now ships fully implemented; user can flip
  when convenient).
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0017 (pinned rt regs X19/R15); ADR-0026 (Cc-pivot).
- ADR-0111 (memory64), ADR-0114 D1/D6 (EH design + zwasm_throw
  trampoline), ADR-0119 (naked-Zig trampoline), **ADR-0120**
  (Proposed; this bundle's payload-marshalling shape).
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md`.
- Lessons (Phase 10 EH cycle):
  - `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  - `2026-05-28-eh-test-wrapper-host-fp-walk-segv.md`
  - `2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`
