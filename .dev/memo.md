# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, **20 (partial)** complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 792/792 (Mac+Ubuntu).
- Real-world: Mac 48/50 (tinygo_sort fixed), Ubuntu TBD (pending merge gate).
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary: 1.29MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**Phase 20: JIT Correctness Sweep — remaining W41 bugs**

Branch: `phase20/tinygo-sort-fix`. tinygo_sort FIXED, ready for merge gate.

### Completed fixes (all Phase 20)

| Fix                                              | Impact                    |
|--------------------------------------------------|---------------------------|
| void-call reloadVreg (ARM64 + x86)               | +5 Mac programs           |
| ARM64 emitMemFill/emitMemCopy/emitMemGrow ABI    | ARM64 memory ops          |
| written_vregs pre-scan (ARM64 + x86)             | +2 Mac (tinygo_hello/json) |
| void self-call result clobber (ARM64 + x86)      | Preventive fix             |
| **ARM64 fuel check x0 clobber** (this branch)    | **tinygo_sort FIXED**      |

**Root cause — fuel check clobbered vreg 20 (x0)**: The ARM64 `emitFuelCheck`
used x0 as a temporary for the fuel counter. But x0 maps to vreg 20 when
reg_count > 20. At loop back-edges, this clobbered vreg 20's live value,
causing incorrect results in the partition loop (wrong sort output).
Fix: use SCRATCH2 (x16/IP0) instead of x0. x86 backend was already correct
(push/pop rax around fuel check).

### Remaining

- `rust_enum_match`: garbage f64 values in Triangle coordinates — FP-related JIT bug
- W42: `go_math_big` wasmtime compat diff (env-dependent, not JIT-related)

### Open Work Items

| Item     | Description                                       | Status         |
|----------|---------------------------------------------------|----------------|
| W41      | JIT real-world: rust_enum_match                   | **Next**       |
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

## Next Session Reference Chain

1. **Orient**: `git log --oneline -5 && git status && git branch`
2. **This memo**: current task, root causes found, remaining bugs
3. **Checklist**: `@./.dev/checklist.md` — W41 updated with tinygo_sort details
4. **JIT debug techniques**: `@./.dev/jit-debugging.md` — dump, ELF wrap, objdump
5. **JIT code** (ARM64): `src/jit.zig` — emitBinop32/64, emitMemStore/Load, getOrLoad, spillCallerSavedLive
6. **JIT code** (x86): `src/x86.zig` — same patterns
7. **Ubuntu testing**: `@./.dev/references/ubuntu-testing-guide.md` — OrbStack VM
8. **Merge gate checklist**: CLAUDE.md → "Merge Gate Checklist" section

### Key next tasks
- **W41 tinygo_sort**: func#87 (89 regs). Approach: capstone disassembly, runtime
  memory comparison, or reg_count bisection 50-89. See checklist for details.
- **W41 rust_enum_match**: FP JIT bug. Separate investigation.

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — W41/W42 details + next steps
- `@./.dev/references/w38-osr-research.md` — OSR research (4 approaches)
- `@./.dev/decisions.md` — architectural decisions (D131: epoch JIT timeout)
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `bench/simd_comparison.yaml` — SIMD performance data
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
