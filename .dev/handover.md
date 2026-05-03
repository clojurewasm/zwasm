# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md` —
   §9.6 / 6.K work-item block (Value funcref, ownership model,
   cross-module imports, element forms 5/7, Label arity, partial-
   init re-measure).
3. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — 6.K.3 done; 6.K.4 + 6.K.5
  + 6.K.6 + 6.E + 6.F〜6.J pending.
- **Last source commit**: `ffc0cf0` — feat(p6) §9.6 / 6.K.3
  cross-module imports + zombie-instance contract. Three-host
  green (Mac + OrbStack + windowsmini test-all). misc-runtime
  244/27 (down from 242/29 baseline; partial-init-table-segment
  + call_indirect.1.wasm + externref-segment recovered).
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.K.4 (`decodeElement` forms 5 / 6 / 7)

Standard `/continue` TDD loop resumes. Per ADR-0014 §2.1 / 6.K.4:
extend `src/frontend/sections.zig:decodeElement` to cover element-
section binary forms 5, 6, 7 (currently only 0 / 1 / 4 are
handled — see ROADMAP "Outstanding spec gaps"). Forms 2 / 5 / 6 /
7 are listed in the gap inventory; ADR-0014 §2.1 / 6.K.4
specifically targets 5 / 6 / 7. Form 2 is the active-segment
explicit-tableidx case which works with the existing imported-
table wiring from 6.K.3.

Step 0 Survey brief: how the wasm-tools / spec interpreter /
zware decode each form; 200-400 lines at
`private/notes/p6-6K4-survey.md`.

## ROADMAP §9.6 — task table snapshot (authoritative is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [x] e6e5c20    |
| 6.K.3 | Cross-module imports for table / global / func + zombie-instance contract (per amended ADR-0014) | [x] ffc0cf0 |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ] **NEXT**   |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |
| 6.K.7 | -Dsanitize=address + zig build run-repro (per ADR-0015)                              | [ ]            |
| 6.K.8 | Error diagnostic M1 (Diagnostic core + CLI parity, per ADR-0016)                     | [x] 306dbc2    |

## Open questions / blockers

(none — 6.K.3 design is locked via the 2026-05-04 ADR-0014
amendment; implementation cycle resumes with the zombie-instance
contract as a co-deliverable. See `private/notes/p6-6K3-lifetime-survey.md`
§4 for the wasmtime / wazero / spec-interpreter cross-reference
that informed the redesign.)

## Phase 6 close → Phase 7 (JIT v1 ARM64) — direct transition

ADR-0014 cancels the placeholder "post-Phase-6 refactor phase"
wiring. Phase 7 is unchanged. The `continue` skill's standard
§9.<N> → §9.<N+1> phase boundary handler applies as-is once
6.K + 6.E + 6.F / 6.G / 6.H / 6.I + 6.J all `[x]`.

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — closes alongside 6.K.5
- element-section forms 2 / 5 / 6 / 7 — closes at 6.K.4
- ref.func declaration-scope — Phase 2 chunk 5e (independent)
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps)
- 39 trap-mid-execution realworld fixtures — through 6.E + 6.K.3
- 10 SKIP-VALIDATOR realworld fixtures
- 29 wasmtime_misc runtime-runner failures (partial fix gated on
  blocker §1 above)
- ADR-0016 M2/M3/M4/M5 — frontend / interp location, C-ABI
  accessors, backtraces (deferred per ADR-0016)
