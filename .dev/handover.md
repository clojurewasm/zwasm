# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `f51d246d` — emscripten_eh PROVENANCE refresh.
  Prior session shipped 27 commits centered on Phase 10.E EH
  codegen end-to-end (Mac aarch64 + Linux x86_64 SysV).
- **ROADMAP §10 progress**: 7/13 DONE (10.0/10.C9/10.J/10.F/
  10.Z/10.D/10.T), 4 IN-PROGRESS (10.M/10.R/10.TC/10.E with
  10.E core substantively done), 2 Pending (10.G/10.P).
- **Active debt rows**: 16 — all `blocked-by:` with named
  structural barriers (Phase 11 / toolchain / GC / v0.2). Zero
  `now`-status rows.
- **D-180 structural defenses STILL IN PLACE** (x86_64
  `usesRuntimePtr` whitelist drift detector + test discipline
  §4 + lesson).

## Session highlights (prior session; for handoff context)

**4 debts closed end-to-end (D-181/D-182/D-183/D-184)**:
- D-181 — memory64 i64-idx ungated for x86_64 SysV.
- D-182 — JIT catch landing pad load+push (per-clause prelude
  pattern; 10.E-payload-prop bundle close).
- D-183 — cross-frame EH dispatch (module-relative PC + DWARF
  ret_addr-1).
- D-184 — x86_64 cross-frame via `loadFrameSniffed` (CodeMap-
  aware sniff disambiguates the `PUSH RBP; PUSH R15; MOV RBP,
  RSP` prologue's `[RBP+0]=saved R15` layout).

**1 bundle closed (10.E-payload-prop; ADR-0120 5 cycles)**:
Runtime.eh_payload_buf + JitRuntime mirror + EmitCtx threading
+ throw.emit pop-N+store-N + per-clause landing-pad prelude.
ADR-0120 Status: Proposed (impl fully shipped + 6 e2e
regressions; user flip to Accepted is purely formal).

**Lessons (3 new this session)**:
- `2026-05-28-eh-catch-landing-pad-per-clause-prelude.md`
- `2026-05-28-x86_64-prologue-rbp-r15-unwinder-mismatch.md`
- (`2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md` already
  shipped pre-session)

**6 JIT e2e EH regressions in `src/engine/runner.zig`**:
single-frame catch_all (42), tagged catch returns 77,
throw+catch_ payload 88, cross-frame catch_all 42, 2-level
cross-frame 77, cross-frame+payload 55, multi-catch
per-clause prelude. Plus 1 interp tail-call chain (frame depth
invariant) + dispatcher unit tests + toModuleRelativePc
contract pin.

## Next candidates (names + Refs; no predictions)

- **10.TC emit-body wiring** — return_call / return_call_indirect
  / return_call_ref JIT emit body. Helpers all shipped
  (10.TC-3a..3e). Pending: per-op `emit` body that integrates
  frame_teardown + arg marshal + emitLoadCalleeRtSameModule +
  emitTailJump. Multi-cycle.
- **10.E spec corpus runner** — `spec_assert_runner_wasm_3_0.zig`
  is a 130-line skeleton (enumerate-and-count). Adding actual
  assert_return / assert_trap / assert_exception execution is
  multi-cycle.
- **10.G WasmGC** — large multi-cycle bundle; design plan +
  ADRs (0115/0116/0117) already shipped.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).
- **10.E follow-on**: c_api tag accessors, cross-module EH
  propagation (v0.2), eh_frequency_runner bench scaffolding
  (Phase 8b).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0017, ADR-0026, ADR-0111, ADR-0114 D1/D5/D6, ADR-0119,
  **ADR-0120** (this session's design — Proposed).
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md`.
- Lessons (Phase 10 EH cycle): see
  `.dev/lessons/INDEX.md` entries 2026-05-26..2026-05-28 (5 EH
  lessons total).
