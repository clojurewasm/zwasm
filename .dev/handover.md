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

- **Phase**: **Phase 6 IN-PROGRESS** — 6.K + 6.E + 6.F all `[x]`.
  6.G〜6.J pending.
- **Last source commit**: `e4095e8` — fix(p6) diff_runner —
  SKIP-WASMTIME-UNUSABLE when every spawn fails.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.G (ClojureWasm guest end-to-end)

Per ROADMAP §9.6 / 6.G: ClojureWasm guest end-to-end via
`build.zig.zon` `path = ...` (original §9.6 / 6.3 strict close).
This wires the in-tree ClojureWasm v2 (`~/Documents/MyProducts/
ClojureWasmFromScratch/`) as a Zig package dependency and runs
its emitted .wasm guest under zwasm.

Step 0 (Survey): inspect ClojureWasmFromScratch's current
build.zig.zon export surface + zwasm v1's prior CW guest harness
to understand the contract. Likely needs a subagent survey.

## ROADMAP §9.6 — task table snapshot (authoritative is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [x] e6e5c20    |
| 6.K.3 | Cross-module imports for table / global / func + zombie-instance contract (per amended ADR-0014) | [x] ffc0cf0 |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [x] 30bb5fd    |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [x] d020317    |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [x] (verify)   |
| 6.K.7 | -Dsanitize=address + zig build run-repro (per ADR-0015)                              | [x] 6750bc5    |
| 6.K.8 | Error diagnostic M1 (Diagnostic core + CLI parity, per ADR-0016)                     | [x] 306dbc2    |
| 6.E   | misc-runtime re-measure + close (266 PASS / 5 deferred via 2 skip-ADRs)              | [x] b569b8f       |
| 6.F   | test-realworld-diff 30+ matches + re-add to test-all (39/50 matched, 0 mismatched)   | [x] (this commit) |

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
