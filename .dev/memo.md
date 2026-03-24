# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, **20 (partial)** complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 792/792 (Mac+Ubuntu).
- Real-world: Mac 47/50, Ubuntu TBD (pending merge gate).
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary: 1.29MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**Phase 20: JIT Correctness Sweep — remaining W41 bugs**

Branch: `phase20/func99-type-confusion`. Two fixes committed, ready for merge gate.

### Completed fixes (this branch)

| Fix                                            | Impact                      |
|------------------------------------------------|-----------------------------|
| written_vregs pre-scan (ARM64 + x86)           | +2 Mac (tinygo_hello, json) |
| void self-call result clobber (ARM64 + x86)    | Preventive (void self-calls)|

**Root cause 1 — written_vregs loop bug**: `written_vregs` bitset was built
incrementally during compilation, so at call sites, only vregs written BEFORE
that PC were tracked. In loops where a vreg is written AFTER a call, the spill
was skipped on later iterations, causing stale values after reload.
Fix: pre-scan ALL instructions before the compile loop.

**Root cause 2 — void self-call result clobber**: `emitInlineSelfCall` used
`self.result_count` (function's declared result count) instead of `n_results`
(actual call-site result count). For void calls to functions that return values,
this loaded the callee's result into rd=0 (vreg 0, x22), clobbering a live reg.

### Next: tinygo_sort func#87 (89 regs, quicksort)

**What**: `sorted 200 integers: false` — sort produces correct first/last values
but some interior elements are out of order. Consistently reproducible.

**Confirmed**: Skipping func#87 from JIT → correct output. Disabling inline
self-calls does NOT fix it (bug is in regular codegen, not self-call path).

**Key facts**:
- 89 regs = 23 physical + 66 spill-only
- 727 IR instructions, 28 locals, 4 params
- Self-recursive (quicksort), void function
- written_vregs pre-scan already applied — not the same bug
- Inner loop has swap ops (lines 113-117) and comparisons
- Needs different debugging approach (memory comparison or targeted tracing)

### Also remaining

- `rust_enum_match`: garbage f64 values in Triangle coordinates — FP-related JIT bug
- W42: `go_math_big` wasmtime compat diff (env-dependent, not JIT-related)

### All Phase 20 fixes

| Fix                                              | Impact                    |
|--------------------------------------------------|---------------------------|
| void-call reloadVreg (ARM64 + x86)               | +5 Mac programs           |
| ARM64 emitMemFill/emitMemCopy/emitMemGrow ABI    | ARM64 memory ops          |
| written_vregs pre-scan (ARM64 + x86)             | +2 Mac (tinygo_hello/json) |
| void self-call result clobber (ARM64 + x86)      | Preventive fix             |

### Open Work Items

| Item     | Description                                       | Status         |
|----------|---------------------------------------------------|----------------|
| W41      | JIT real-world: tinygo_sort, rust_enum_match      | **Next**       |
| W42      | wasmtime 互換性差異 (go_math_big, Mac)             | Low priority   |
| Phase 18 | Lazy Compilation + CLI Extensions                 | Future         |

## Completed Phases (summary)

| Phase    | Name                                  | Date       |
|----------|---------------------------------------|------------|
| 1        | Guard Pages + Module Cache            | 2026-03    |
| 3        | CI Automation + Documentation         | 2026-03    |
| 5        | C API + Conditional Compilation       | 2026-03    |
| 8        | Real-World Coverage + WAT Parity      | 2026-03    |
| 10       | Quality / Stabilization               | 2026-03    |
| 11       | Allocator Injection + Embedding       | 2026-03    |
| 13       | SIMD JIT (NEON + SSE)                 | 2026-03-23 |
| 15       | Windows Port                          | 2026-03    |
| 19       | JIT Reliability                       | 2026-03    |
| 20 (wip) | JIT Correctness Sweep                 | 2026-03-25 |

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — W41/W42 details + next steps
- `@./.dev/references/w38-osr-research.md` — OSR research (4 approaches)
- `@./.dev/decisions.md` — architectural decisions (D131: epoch JIT timeout)
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `bench/simd_comparison.yaml` — SIMD performance data
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
