# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **13 IN-PROGRESS — C API full (wasm-c-api conformance)**. **Phase 12 (AOT) DONE** — §12.P closed
  (ADR-0141): `.cwasm` compile/run loader (§12.1) + JIT↔AOT differential (§12.2) + toolchain cross-compile
  (§12.3) + stateful-COMPUTE exec — globals/memory/tables/`call_indirect` (§12.3b) + cold-start ≥30% (§12.4:
  6/6 SIMD fixtures 33-37% AOT-faster). **Deferred to Phase 15**: §12.5 stack-map (co-defines with the GC
  `GcRootMap` shape, ADR-0141, with §11.4 rooting). **Deferred D-251**: WASI/host imports in AOT (parity with
  JIT compute-only, ADR-0140 — lands with JIT-WASI d-3 / D-244).
- **Phase 13 opened**; §13.0 [x] (widget) + **§13.1 [x]** — `wasm.h` surface audit DONE
  (`.dev/phase13_capi_gap.md`: 54/135 impl, gap list by category). 🔒 = END-of-phase conformance gate, not entry.

## Next task (autonomous)

§13.2 — implement missing `wasm.h` surface, category-by-category (gap list: `.dev/phase13_capi_gap.md`; 54/135
impl). **First chunk = type constructors + queries** (load-bearing — `func_new`/`global_new`/`table_new`/
`memory_new` consume `*type` objects): `wasm_{valtype,functype,globaltype,tabletype,memorytype}_new/_delete/
_copy` + query accessors (valtype_kind, functype_params/results, globaltype_content/mutability, tabletype_
element/limits, memorytype_limits) + their vecs. Impls go in a new `src/api/types.zig` (or extend `instance.zig`)
+ re-export via `api/wasm.zig`; mirror the upstream wasm-c-api shapes (`include/wasm.h`). Red test: a Zig test
constructing a functype + reading params/results back. Then externtype/import-export types, the `_new`
constructors, frames/foreign, module_imports/exports. Step 0 mostly done (gap doc); per-category survey as needed.

## Phase-12 close note

Phase 12 closed `0810b339` (ADR-0141). audit_scaffolding ran (0 block; `private/audit-2026-06-03-p12close.md`).
**windowsmini 3-host reconcile GREEN** — `/tmp/win.log` 1748 lines, 0 failed/mismatched across edge-case/spec/
spec_assert/diff_runner + realworld (no Win64 drift; Phase 12 added no Win64-exec paths). §12 SHAs inline in row
prose. Standing `soon` (not Phase-12): 10 ADR + 10 lesson `<backfill>` markers; 8 files over soft cap.

## Deferred / open debt (none a Phase-13 blocker)

- **§12.5 / §11.4** GC stack-map (AOT) + precise rooting → Phase 15 (ADR-0141 / ADR-0135; D-211).
- **D-251** WASI/host imports in AOT — with JIT-WASI d-3 (D-244); ADR-0140.
- **D-249** Windows bench timing (hyperfine on windowsmini) — perf-completeness, ADR-0137.
- **D-245** host→JIT callee-saved (win64 + arg'd remainder). **D-246** §11.3 arm64 dot/extmul → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. D-210/D-234/D-237/D-229/D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn = §13.1 gap audit (`.dev/phase13_capi_gap.md`) + §13.1 [x] + windowsmini reconcile verified GREEN
(above). No new `src/` this turn (gap doc + ROADMAP/handover only) → no ubuntu kick owed. Last code HEAD
verified ubuntu = `cf32e57a` (Mac+ubuntu); windowsmini = `0810b339` reconcile GREEN. Next resume: start §13.2
type constructors (no host verification pending).

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §13 (C API — Goal/exit + §13 task table); Phase Status widget (Phase 12 DONE / 13 IN-PROGRESS).
- ADR-0141 (Phase-12 close, §12.5→P15); ADR-0140 (WASI defer, §12.4 compute-scope); ADR-0139 (P12 re-sequence);
  ADR-0138 (`.cwasm` v0.2/0.3). `api/wasm.zig` + `include/wasm.h` = §13 surface. `cli/run.zig` drives the C API.
