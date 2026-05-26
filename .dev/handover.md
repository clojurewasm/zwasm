# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `ae2abab7` — x86_64 return_call_indirect emit body
  (10.TC emit-body cycle 8; JMP R11 path).
- **ROADMAP §10 progress**: 7/13 DONE (10.0/10.C9/10.J/10.F/
  10.Z/10.D/10.T), 4 IN-PROGRESS (10.M/10.R/10.TC/10.E with
  10.E core substantively done), 2 Pending (10.G/10.P).
- **Active debt rows**: 16 — all `blocked-by:` with named
  structural barriers (Phase 11 / toolchain / GC / v0.2). Zero
  `now`-status rows.
- **D-180 structural defenses STILL IN PLACE** (x86_64
  `usesRuntimePtr` whitelist drift detector + test discipline
  §4 + lesson).

## Active bundle

- **Bundle-ID**: 10.TC-emit-body
- **Cycles-remaining**: ~2
- **Continuity-memo**: cycles 1-8 landed (cycle 6 reverted + re-
  applied via cycle 7's D-185 fix). Same-module direct
  `return_call` complete on both arches; `return_call_indirect`
  arm64 (cycle 6, re-applied at `73187e6f`) + x86_64 (cycle 8,
  `ae2abab7`) both wired to the JMP R11 / BR X16 path. Single-
  table fast-path scope (table_idx==0, results.len<=2) on both
  arches. Cycle 7 lesson `shared-facade-host-dispatched-cross-arch-
  byte-test` filed.
- **Exit-condition**: x86_64 SysV mirror of cycle 3 wired
  end-to-end (JMP rel32 opcode at emit + emitDirectReturnCall
  + same e2e fixture green on Linux x86_64) AND `return_call_
  indirect` / `return_call_ref` arm64+x86_64 wired with at
  least one e2e fixture each.
- **Next cycle (cycle 9)**: `return_call_ref` arm64 + x86_64
  emit body. Wasm 3.0 §3.3.8.20 — pops a funcref from the stack
  (instead of via table index), validates non-null, BR/JMP to
  the resolved funcptr. Sub-steps: (a) arm64
  `op_tail_call.emitRefReturnCall(ctx, ins)`: pop funcref vreg
  → X16, null-check (CBZ → trap), MOV X0 ← X19,
  frame_teardown, BR X16. ins.payload = (ref $sig) type index
  for validation (already enforced at validator stage). (b)
  x86_64 mirror: pop funcref → R11, TEST R11,R11 + JZ → trap,
  MOV RDI ← R15, frame_teardown, JMP R11. (c) Wire both
  per-op stubs to delegate. (d) Add to dispatch (arm64 manual
  switch + x86_64 collected_x86_64_ctx_ops 396 → 397). (e)
  Add `.return_call_ref` to x86_64 usesRuntimePtr whitelist.
  (f) Byte-snapshot test for both arches.

## Session highlights (prior session; for handoff context)

- 4 debts closed end-to-end (D-181/D-182/D-183/D-184).
- 1 bundle closed (10.E-payload-prop; ADR-0120 5 cycles).
- 3 new lessons (`2026-05-28-eh-catch-landing-pad-per-clause-prelude`,
  `2026-05-28-x86_64-prologue-rbp-r15-unwinder-mismatch`,
  `2026-05-28-x86_64-uses-runtime-ptr-eh-gap`).
- 6 JIT e2e EH regressions + 1 interp tail-call chain test +
  dispatcher unit tests + toModuleRelativePc contract pin.

## Next candidates (after 10.TC-emit-body bundle closes)

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

- ADR-0017, ADR-0026, ADR-0111, ADR-0112 (tail-call design;
  governs the active bundle), ADR-0113 §A (terminator class),
  ADR-0114 D1/D5/D6, ADR-0119, ADR-0120.
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md` Row 10.TC.
- Lessons (Phase 10 EH cycle): see
  `.dev/lessons/INDEX.md` entries 2026-05-26..2026-05-28 (5 EH
  lessons total).
