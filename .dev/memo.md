# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19 all complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 792/792 (Mac+Ubuntu).
- Real-world: Mac 44/50 (up from 41, +3 from void-call fix).
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary: 1.29MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**Phase 20: JIT Correctness Sweep** — in progress.

W38 (Lazy AOT) で HOT_THRESHOLD を 10→3 に下げた結果、以前は JIT されなかった
関数がコンパイルされるようになり、潜在 JIT バグが露出した。
Spec は 100% だが、real-world プログラムに影響がある。これらを修正するフェーズ。

### Progress

**Fixed: emitCall reloadVreg for void calls (ARM64 + x86)**
- Root cause: When a wasm `call` targets a function with 0 results, regalloc
  sets `rd=0` (dummy). JIT's `emitCall` unconditionally called `reloadVreg(rd)`
  after the trampoline BLR, which loaded a stale value from `regs[0]` into the
  physical register for vreg 0 (x22 on ARM64), clobbering a live local variable.
- Symptom: func#206 in tinygo_hello called func#124 (interfaceTypeAssert, 0 results)
  with rd=0. After the call, x22 (local 0 = stack pointer) was overwritten with 0
  (the initial zero-filled value of regs[0]). Then `global.set 0` restored g0 = 80
  instead of the correct ~64912.
- Fix: encode `n_results` in `rs2_field` of OP_CALL and OP_CALL_INDIRECT instructions.
  Skip `reloadVreg(rd)` when `n_results == 0`. Applied to both ARM64 and x86 backends.
- Also fixed emitCallIndirect with the same pattern.

**Fixed: ARM64 emitMemFill/emitMemCopy/emitMemGrow ABI register clobbering**
- `getOrLoad` returns physical registers that alias ABI arg registers (x0-x3)
- Sequential ABI arg setup clobbers vreg values before they're read
- Fix: spill all arg vregs to memory, load from regs[] into ABI regs
- x86 backend already had this fix; ARM64 did not

### Real-world status after fixes (Mac)

| Program          | Before | After | Notes                              |
|------------------|--------|-------|------------------------------------|
| rust_compression | DIFF   | PASS  | Fixed by void-call fix             |
| rust_serde_json  | DIFF   | PASS  | Fixed by void-call fix             |
| rust_enum_match  | DIFF   | DIFF  | ARM64 JIT float issue, needs more  |
| tinygo_hello     | DIFF   | DIFF  | type assert failed (separate bug)  |
| tinygo_json      | DIFF   | DIFF  | Needs investigation                |
| tinygo_sort      | DIFF   | DIFF  | ARM64 JIT output diff              |
| go_math_big      | DIFF   | DIFF  | W42, not JIT-related               |
| rust_file_io     | ?      | DIFF  | Needs investigation                |

### Bisection results (next session)

**tinygo_hello** has TWO separate bugs:
1. func#154 (12 regs): causes crash ("type assert failed" → unreachable)
   - Skipping func#154 from JIT avoids the crash
2. func#99 (57 regs, 614 IR, 16 locals): causes type confusion
   - `argv[1] = %!s(int=1)` instead of `argv[1] = arg1`
   - Skipping func#99 from JIT produces correct output
   - 57 regs means 34 spill-only vregs (>= 23)
   - All calls in func#99 except line 20 have n_results=0 (void calls)
   - Void-call fix IS applied, but output still wrong → different root cause
   - Large reg_count + complex control flow (614 instrs) — likely a codegen
     issue specific to high-reg functions

**rust_enum_match**: JIT produces garbage float values in triangle output
(`6094179727183252...` instead of `33.9`). Float register corruption.

### Remaining work

- 6 programs still failing on Mac (4 JIT-related, 1 W42, 1 rust_file_io)
- Ubuntu testing needed for void-call fix verification

### Open Work Items

| Item     | Description                                       | Status       |
|----------|---------------------------------------------------|--------------|
| W41      | JIT real-world correctness (6→4 remaining)        | In progress  |
| W42      | wasmtime 互換性差異 (go_math_big, Mac)             | Low priority |
| Phase 18 | Lazy Compilation + CLI Extensions                 | Future       |

## Completed Phases (summary)

| Phase | Name                                  | Date       |
|-------|---------------------------------------|------------|
| 1     | Guard Pages + Module Cache            | 2026-03    |
| 3     | CI Automation + Documentation         | 2026-03    |
| 5     | C API + Conditional Compilation       | 2026-03    |
| 8     | Real-World Coverage + WAT Parity      | 2026-03    |
| 10    | Quality / Stabilization               | 2026-03    |
| 11    | Allocator Injection + Embedding       | 2026-03    |
| 13    | SIMD JIT (NEON + SSE)                 | 2026-03-23 |
| 15    | Windows Port                          | 2026-03    |
| 19    | JIT Reliability                       | 2026-03    |

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — W38/W41/W42 details
- `@./.dev/references/w38-osr-research.md` — OSR research (4 approaches)
- `@./.dev/decisions.md` — architectural decisions (D131: epoch JIT timeout)
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `bench/simd_comparison.yaml` — SIMD performance data
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
