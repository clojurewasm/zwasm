# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `3d2600ca` — feat(p10): relax MultiMemoryUnsupported
  for defined memories (10.M cycle 62, bundle open). Two
  defined-memory gates in `instantiate.zig` relaxed: defined memory
  section now loop-allocates N `MemoryInstance` entries; active data
  segments route to `rt.memories[seg.memidx]` with per-target bounds
  + idx_type. Imports still capped at 1; memidx > 0 memory ops
  still pinned to memories[0] in emit. Mac aarch64 test-all + lint
  green.
- **D-188 FULLY DISCHARGED** (cycle 61) — wasm-3.0-assert
  `assert_invalid pass=118 fail=0`. **D-194 / D-195(c) DISCHARGED**
  earlier. Active debt rows: 16 — all `blocked-by:`; zero `now` rows.

## Active bundle

- **Bundle-ID**: 10.M-multi-memory
- **Cycles-remaining**: ~3
- **Continuity-memo**: ADR-0111 (memory64 + multi-memory design).
  Cycle 62 (`3d2600ca`): relaxed defined-memory + active-data
  segment gates. Remaining work:
  - **Cycle 63 candidate**: relax import-side memory cap (line 806
    `imp_memory_count > 1 → MultiMemoryUnsupported`). Requires
    import binding shape extension to carry N memories per import
    set OR pre-loop iteration. Examine `bindings.?[idx].memory`
    structure first.
  - **Cycle 64 candidate**: MemArgExtra.memidx > 0 plumbing through
    emit so memory ops route to `rt.memories[memidx]` instead of
    the implicit memories[0]. Touches arm64/x86_64 codegen + the
    runtime memory-base pointer materialise. ADR-0111 D2 says
    "codegen-zero" for memidx=0; memidx>0 needs explicit base
    materialise from `rt.memories[N].bytes.ptr`.
  - **Cycle 65 candidate**: bake multi-memory raw corpus from
    upstream `memory64/test/core/multi-memory/` + wire into spec
    runner.
- **Exit-condition**: spec runner shows ≥1 multi-memory return/trap
  fixture passing on both arches (e.g. `memory_size0.wast` with
  size queries on memidx 0 + memidx 1).

## Active task — cycle 63: import memory cap relax

Smallest red: hand-craft a wasm that imports 2 memories (or 1 import
+ 1 defined) — currently `error.MultiMemoryUnsupported` at line 806.
Examine `ImportBinding` shape in `src/runtime/instance/import.zig`;
the binding-supplier API needs to deliver multiple memory bindings.
If the supplier shape is already N-friendly, the loop relaxation is
mechanical. If not, file a debt note for the API extension and pick
a different cycle-63 target (e.g., MemArgExtra.memidx > 0 emit, the
cycle-64 candidate).

## Larger §10 work (blocked / later)

- **10.M memory64 multi-memory** — IN-PROGRESS bundle (cycle 62
  open). Single-memory memory64 already green.
- **10.E EH** — validator side spec-correct as of cycle 61;
  runtime EH dispatch + cross-module register (D-192) remain
  external-gated.
- **10.G WasmGC op-corpus** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-62; counts unchanged from cycle-61)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4)  invalid=18(pass=18 fail=0)
[wasm-3.0-assert    ] assert_invalid pass=118 fail=0
```

(Cycle 62 substrate change is invisible to the runner — multi-memory
corpus not yet baked.)

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-192 — EH return/trap fixtures blocked on cross-module register +
  exnref ValType.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0111 (memory64 + multi-memory design) — active bundle anchor.
- ADR-0122 (test skip categorization) — D-193 discharge complete.
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- ROADMAP §10 row 10.M; `.dev/phase_log/phase10.md`.
