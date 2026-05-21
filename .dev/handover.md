# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10` — last code commit: `30ae661f`
   (ADR-0090 — regalloc_shape_tags.zig extraction;
   regalloc.zig 1851 → 1529 LOC; mirror of ADR-0088
   re-export pattern; Accepted same cycle). **Session
   total: 11 D-141 closures + 3 lessons captured.**
2. **User directive (2026-05-21)**: batch-session architectural
   mode — Phase 9 closure quality. Substantially advanced.
3. **Live status**: `bash scripts/p9_completion_status.sh` —
   D-055 `Status: now`; D-081 blocked.

## Authorized next-session pickup (priority order — 2026-05-21)

**Mechanical-extraction sweep is exhausted.** 11 D-141 closures
this session covered every file with a clean single-cycle
extraction shape (re-export / pure top-level helper / struct-
method-mirror-of-ADR-0083). Remaining files need ADR-grade
design surveys before extraction can proceed.

1. **REMAINING D-141 candidates — all need ADR-grade survey
   (NOT single-cycle mechanical)**:
   - **parse/sections.zig** (1556 LOC) — 16 small structs
     interleaved with 10+ decoders. Design choice: per-section
     split (7+ new files, ADR-0080 fragmentation trap) vs
     Wasm-version-cohort split (sections_core / sections_2_0)
     vs FILE-SIZE-EXEMPT marker.
   - **api/instance.zig** (1431 LOC) — c_api Instance
     lifecycle; 7 fns with many file-internal dependencies
     (buildBindings calls parkAsZombie / lookupSourceExportType
     / dispatchTable). Re-export pattern does NOT apply.
     §9.12-G item — needs c_api lifecycle redesign.
   - **engine/compile.zig** (1225 LOC) — one huge
     `pub fn compileWasm` spanning lines 29-903 (~875 LOC).
     Extraction requires breaking compileWasm into phased
     sub-fns (parse / validate / lower / emit / link). ADR-grade.
   - **regalloc.zig** (1529 LOC after ADR-0090) — still over
     soft cap. Compute/verify/vreg-class axis split possible
     but needs design choice on which to extract first.
2. **D-055 discharge (independent)**. ~95 hardcoded byte-offset
   sites migrate; mechanical, multi-cycle.
3. **§9.12-G `src/api/instance.zig` split** (per c_api lifecycle).
4. **§9.12-H bench baseline** (Mac Wasm 2.0 + wasmtime).
5. **§9.12-I ADR/lesson curation closure**.

## Active state (snapshot)

- **§9.12-A enforcement**: 9 items OK; gate_commit + pre-push
  audit gates active. §9.12-E [x] at `7b2e1b02`.
- **ADR-0078 fully load-bearing**: G.1.1 + G.1.2 + amendment.
- **§9.12-G partial**: 41 Wasm 3.0 stubs landed; dispatcher
  comptime-reject; CLI --invoke.
- **§9.12-F**: **11 D-141 slots closed THIS session**
  (runner.zig / x86_64-emit.zig / ir-dispatch_collector /
  validator / arm64-inst / arm64-emit / codegen-dispatch_collector
  / ir-zir / ir-liveness / ir-lower / regalloc). ADRs 0079
  +0081+0082+0083+0084+0085+0086+0087+0088+0089+0090 all
  Accepted. 3 lessons captured (cross-file-struct-method-syntax-
  zig-0-16 / emit-zig-survey-per-op-pattern-already-absorbed /
  pure-data-extraction-via-reexport).

## Pattern menu (for next-session reference)

| Pattern | When applicable | Examples |
|---|---|---|
| Pure-data re-export | One block > 40% LOC, no methods, no state | ADR-0082, 0086, 0087, 0088, 0090 |
| Pure top-level helper | 3+ standalone helpers, no callers, simple imports | ADR-0079, 0081, 0085 |
| Cross-file struct method | Struct-method-heavy file with SIMD or other clean axis | ADR-0083, 0089 |
| Per-caller migration | N independent symbols, 100+ caller sites | ADR-0084 |

See lesson `2026-05-21-pure-data-extraction-via-reexport.md`
survey checklist before drafting the next per-file ADR.

## Operational note for the batch-session loop

`/continue` resume Steps 0-7 apply per cycle. Granularity
`architectural`. Cite ADR-0079/0081/0082/0083/0086/0088 shape
precedents in commit bodies. Remaining work needs survey-first
discipline (not assume the same mechanical pattern will apply).

## Open questions / blockers

- なし。autonomous batch-session at natural breakpoint —
  mechanical-extraction sweep complete; next surface needs
  design choices.

## See

- [ROADMAP](./ROADMAP.md) §9.12 — F (D-141 sweep partial) / G / H / I open.
- [`debt.md`](./debt.md) — 24 active rows.
- [`decisions/0090_regalloc_shape_tags_extraction.md`](./decisions/0090_regalloc_shape_tags_extraction.md)
  — most recent extraction.
- [`lessons/INDEX.md`](./lessons/INDEX.md) — 3 lessons from this session.
