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
   Phase 6 reopen scope (6.A〜6.J + appended 6.K per ADR-0014).

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D + 6.K.1 + 6.K.2 done;
  ADR-0015 + ADR-0016 phase 1 done; 6.K.3〜6.K.6 + 6.K.7 + 6.E +
  6.F〜6.J pending).
- **Last source commit**: `306dbc2` — feat(p6) land ADR-0016
  phase 1 (Diagnostic core + CLI parity). Three-host green.
  v1 → v2 CLI parity recovered for the runWasm boundary
  (malformed wasm now prints `zwasm: instantiation failed for
  ... — module decode/validate failed ...`, not the bare
  `zwasm run: ModuleAllocFailed`).
- **ADRs landed today**: ADR-0014 (K-stream redesign), ADR-0015
  (debug toolkit), ADR-0016 (error diagnostic system, M1 only —
  M2-M5 deferred).
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.K.3 (cross-module imports for table / global / func)

Standard `/continue` TDD loop resumes — Step 0 Survey → Plan →
Red → Green → Refactor → three-host gate → source commit →
handover update + push + re-arm.

Per ADR-0014 §2.1 / 6.K.3: drop the
`error.UnsupportedCrossModuleTableImport` /
`UnsupportedCrossModuleGlobalImport` /
`UnsupportedCrossModuleFuncImport` returns at
`src/c_api/instance.zig` ~line 593–602 and wire the actual
import paths. Builds on 6.K.1's `*FuncEntity` pointer encoding
(commit `296d78e`) and 6.K.2's single-allocator Runtime + Instance
back-ref (commit `e6e5c20`); the `FuncEntity.runtime` back-ref
is what makes cross-module dispatch addressable without a
separate routing table.

Step 0 Survey brief should target:

- v1's import resolution path (~`src/c_api/*` + `src/runtime/*`,
  read-only)
- wasmtime's `wasmtime/src/runtime/instance.rs` import-binding
  flow
- zware's import handling (Zig idiom)
- v2's existing iter-7 memory-import branch (`instance.zig`
  ~700–725) as the precedent shape — extend to table / global /
  func

Survey output lands in `private/notes/p6-6K3-survey.md`.

`test-wasmtime-misc-runtime` baseline standing at 242 / 29; this
row plus 6.K.4 / 6.K.5 / 6.K.6 are expected to drain those fails
toward 6.E's re-measure.

## ROADMAP §9.6 — §9.6 / 6.K rows (authoritative table is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [x] e6e5c20    |
| 6.K.3 | Cross-module imports for table / global / func (after 6.K.1 + 6.K.2)                 | [ ] **NEXT**   |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ]            |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |
| 6.K.7 | -Dsanitize=address + zig build run-repro (per ADR-0015)                              | [ ]            |
| 6.K.8 | Error diagnostic M1 (Diagnostic core + CLI parity, per ADR-0016)                     | [x] 306dbc2    |

After 6.K all-`[x]`, 6.E re-measures (29 fails flow through),
then 6.F / 6.G / 6.H, 6.I parallel, then 6.J strict close.

## Phase 6 close → Phase 7 (JIT v1 ARM64) — direct transition

ADR-0014 cancels the placeholder "post-Phase-6 refactor phase"
wiring. Phase 7 is unchanged (JIT v1 ARM64 baseline), no renumber.
The `continue` skill's standard §9.<N> → §9.<N+1> phase boundary
handler applies as-is once 6.K + 6.E + 6.F / 6.G / 6.H / 6.I +
6.J all `[x]`.

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — closes alongside 6.K.5
- element-section forms 2 / 5 / 6 / 7 — closes at 6.K.4
- ref.func declaration-scope — Phase 2 chunk 5e (independent)
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps)
- 39 trap-mid-execution realworld fixtures — through 6.E + 6.K.3
- 10 SKIP-VALIDATOR realworld fixtures
- 29 wasmtime_misc runtime-runner failures (resolved through
  6.K per ADR-0014 §2.1)
- ADR-0016 M2/M3/M4/M5 — frontend / interp location, C-ABI
  accessors, backtraces (deferred per ADR-0016; pre-v0.1.0
  scheduling decided once §9.6 / 6.K closes)

## Open questions / blockers

(none — autonomous loop continues 6.K.3 → 6.K.4 → 6.K.5 → 6.K.6 →
6.K.7 → 6.E re-run → 6.F / 6.G / 6.H / 6.I → 6.J.)
