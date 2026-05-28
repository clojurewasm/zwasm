# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `5bd57371` — feat(p10): interp MemArgExtra.memidx > 0
  routing (10.M cycle 64). All 24 interp load/store handlers in
  `src/instruction/wasm_1_0/memory.zig` migrated to consult
  `MemArgExtra.unpack(instr.extra).memidx` via the new
  `memorySlice` helper. End-to-end round-trip test (i32.store +
  i32.load via memidx=1) passes. Mac aarch64 test-all + lint green.
- **D-188 FULLY DISCHARGED** (cycle 61). **D-194 / D-195(c)
  DISCHARGED** earlier. Active debt rows: 16 — all `blocked-by:`;
  zero `now`.

## Active bundle

- **Bundle-ID**: 10.M-multi-memory
- **Cycles-remaining**: ~1
- **Continuity-memo**: ADR-0111 (memory64 + multi-memory design).
  Cycles 62-64 landed: defined-memory + data-segment + imported-
  memory caps relaxed; interp load/store memidx>0 routing wired.
  Remaining:
  - **Cycle 65 candidate (next)**: bake one simple multi-memory
    fixture from upstream `~/Documents/OSS/WebAssembly/memory64/
    test/core/multi-memory/memory_size0.wast` (or `data0.wast`)
    into `test/spec/wasm-3.0-assert/multi-memory/raw/` →
    `regen_spec_3_0_assert.sh` bake → wire into spec runner. NOTE
    the corpus uses `memory.size` / `memory.grow` with
    memidx > 0 in some fixtures; `lower.zig::emitMemoryReserved`
    currently rejects non-zero memidx (`if (body[pos] != 0x00)
    return BadBlockType`). May need a sibling relax in lower.zig
    before the corpus bake compiles. Pick `data0.wast` first if it
    only uses load/store (already wired this cycle).
  - **Stretch / cycle 66**: relax `lower.zig::emitMemoryReserved`
    + thread memidx through to memory.size / memory.grow handlers.
- **Exit-condition**: spec runner shows ≥1 multi-memory return/trap
  fixture passing on the interp path (JIT memidx > 0 is a separate
  future bundle).

## Active task — cycle 65: bake first multi-memory spec fixture

Smallest red:
1. Add `multi-memory` proposal entry to `scripts/import_proposal_
   corpus.sh` pointing at `memory64/test/core/multi-memory`.
2. Copy one .wast (`data0.wast` is a candidate — uses defined
   memories + data segments + load/store, no memory.size/grow).
3. Run `regen_spec_3_0_assert.sh multi-memory data0` → produces
   `test/spec/wasm-3.0-assert/multi-memory/data0/`.
4. Add manifest registration to `spec_assert_runner_wasm_3_0.zig`'s
   PROPOSALS list (or new `multi-memory` proposal name).
5. Run spec runner → verify the new manifest passes its
   assert_return/assert_trap directives.

If `data0.wast` fixtures use `memory.size`/`grow` with memidx > 0,
fall back to a hand-picked simpler fixture or defer to cycle 66.

## Larger §10 work (blocked / later)

- **10.M memory64 multi-memory** — IN-PROGRESS bundle (cycles 62-64
  landed; cycle 65 = corpus baking).
- **10.E EH** — validator side spec-correct (cycle 61); runtime EH
  dispatch + cross-module register (D-192) external-gated.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-64; unchanged from cycle-61)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4)  invalid=18(pass=18 fail=0)
[wasm-3.0-assert    ] assert_invalid pass=118 fail=0
```

Cycles 62-64 are observable via the new in-source tests
(`10.M cycle 62/64`) but not yet via the spec runner.

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
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- ROADMAP §10 row 10.M; `.dev/phase_log/phase10.md`.
