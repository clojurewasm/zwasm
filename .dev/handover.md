# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `f2a8a84e` — feat(p10): relax MultiMemoryUnsupported for
  imported memories (10.M cycle 63). Import path loop-allocates N
  `MemoryInstance` entries (mirror of cycle-62 defined-memory path).
  Behaviour-neutral for 0/1-import cases; N-import path latent until
  corpus baking exercises it. Mac aarch64 test-all + lint green.
- **D-188 FULLY DISCHARGED** (cycle 61): `assert_invalid pass=118
  fail=0` across wasm-3.0-assert. **D-194 / D-195(c) DISCHARGED**
  earlier. Active debt rows: 16 — all `blocked-by:`; zero `now`.

## Active bundle

- **Bundle-ID**: 10.M-multi-memory
- **Cycles-remaining**: ~2
- **Continuity-memo**: ADR-0111 (memory64 + multi-memory design).
  Cycle 62 (`3d2600ca`): defined-memory + data-segment gates
  relaxed. Cycle 63 (`f2a8a84e`): imported-memory cap relaxed. Now:
  - **Cycle 64 candidate (next)**: MemArgExtra.memidx > 0 plumbing.
    Interp memory ops in `src/instruction/wasm_1_0/memory.zig` hard-
    pin to `rt.memory` (= memories[0]); extend to read `MemArgExtra.
    unpack(instr.extra).memidx` and route via `rt.memories[memidx].
    bytes`. Touches every load/store/n-form/size/grow/copy/fill/init
    handler — bundle this group together (single shared substrate
    change). JIT codegen path is a separate sibling (out of scope
    for cycle 64; tackled in cycle 65 alongside corpus baking).
  - **Cycle 65 candidate**: bake multi-memory raw corpus from
    upstream `~/Documents/OSS/WebAssembly/memory64/test/core/multi-
    memory/` into `test/spec/wasm-3.0-assert/multi-memory/raw/` →
    select 1-2 simplest .wast (e.g., `memory_size0.wast`) →
    `regen_spec_3_0_assert.sh` bake → wire into runner.
- **Exit-condition**: spec runner shows ≥1 multi-memory return/trap
  fixture passing on at least the interp path (JIT memidx > 0 is a
  separate bundle).

## Active task — cycle 64: MemArgExtra.memidx > 0 plumbing (interp)

Smallest red: an in-source unit test that builds a 2-memory module +
function that does `i32.load (memory 1)` from memidx 1; the function
returns 0 (uninitialized memory). Pre-change: interp hits memories[0]
silently, returning whatever's at memories[0][0..4] (= 0 anyway, but
the wrong path). Post-change: routes to memories[1].

Surface: `MemArgExtra.unpack(instr.extra).memidx` lookup per handler
in `src/instruction/wasm_1_0/memory.zig` (and SIMD memory ops in
`wasm_2_0/simd_memory.zig` if any). Replace `rt.memory` with
`rt.memories[memidx].bytes`. Per-target bounds check + per-target
idx_type (for offset width).

## Larger §10 work (blocked / later)

- **10.M memory64 multi-memory** — IN-PROGRESS bundle (cycle 62-63
  open; ~2 cycles remaining).
- **10.E EH** — validator side spec-correct (cycle 61); runtime EH
  dispatch + cross-module register (D-192) external-gated.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-63; unchanged from cycle-61)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4)  invalid=18(pass=18 fail=0)
[wasm-3.0-assert    ] assert_invalid pass=118 fail=0
```

(Cycles 62-63 substrate change is invisible to the runner — multi-
memory corpus not yet baked.)

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
