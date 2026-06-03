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
- **Phase 13 opened**; §13.0 [x], §13.1 [x] (gap audit `.dev/phase13_capi_gap.md`). **§13.2 in progress** —
  type-constructor group DONE (`7ac09d80`, `src/api/types.zig`): valtype/functype/globaltype/tabletype/
  memorytype `_new/_delete/_copy` + queries + `valtype_vec` (pointer-vec, element-cascade delete, deep-copy);
  re-exported via `api/wasm.zig`, barrel in `zwasm.zig`. Mirrors upstream ownership (functype_new consumes the
  vecs; queries return borrowed). 🔒 = END-of-phase conformance gate, not entry.

## Next task (autonomous)

§13.2 next category — **externtype + import/export types** (build on the type constructors `7ac09d80`; module_
imports/exports return these). In `api/types.zig`: `wasm_externtype_t` (a tagged union over func/global/table/
memory type) + `wasm_externtype_kind` + `wasm_externtype_as_{func,global,table,memory}type[_const]` (both
directions: `wasm_{func,global,table,memory}type_as_externtype`); then `wasm_importtype_t` (module+name+
externtype) / `wasm_exporttype_t` (name+externtype) `_new/_delete/_copy` + queries + their vecs. See
`include/wasm.h` lines ~250-330 + `.dev/phase13_capi_gap.md`. Then (later chunks): func/global/table/memory
`_new` constructors (Store-coupled → may extend `instance.zig`), frames/foreign, module_imports/exports.

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

This turn landed §13.2 type constructors (`7ac09d80`, `src/api/types.zig`): Mac test+build(C-API lib)+lint+zone
green. An ubuntu `test` is kicked against this turn's HEAD → next resume `tail /tmp/ubuntu.log` for OK (the
type constructors are pure-data + c_allocator, host-portable; ubuntu verifies x86_64 link + the test block).
Prior ubuntu `cf32e57a` OK; windowsmini `0810b339` reconcile GREEN.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §13 (C API — Goal/exit + §13 task table); Phase Status widget (Phase 12 DONE / 13 IN-PROGRESS).
- ADR-0141 (Phase-12 close, §12.5→P15); ADR-0140 (WASI defer, §12.4 compute-scope); ADR-0139 (P12 re-sequence);
  ADR-0138 (`.cwasm` v0.2/0.3). `api/wasm.zig` + `include/wasm.h` = §13 surface. `cli/run.zig` drives the C API.
