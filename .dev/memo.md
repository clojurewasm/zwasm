# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, **20 (partial)** complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 792/792 (Mac+Ubuntu).
- Real-world: Mac 46/50, Ubuntu 48/50.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary: 1.29MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**Phase 20: JIT Correctness Sweep — remaining W41 bugs**

Void-call fix merged to main. 4 real-world programs still fail on Mac (2 on Ubuntu).
Next task: investigate func#99 (high reg_count type confusion).

### Next: func#99 type confusion (tinygo_hello, likely tinygo_json)

**What**: func#99 (57 regs, 614 IR, 16 locals) in `tinygo_hello.wasm` produces
type confusion: `%!s(int=1)` instead of `arg1`. TinyGo interface type tags
are written incorrectly to linear memory.

**Confirmed by bisection**: Skipping func#99 from JIT → correct output.
Only func#99 (not func#154 or others) causes this specific issue.

**Key facts**:
- 57 regs = 23 physically-mapped + 34 spill-only (regs[23..56] always in memory)
- All calls except IR line 20 are void (rd=0, n_results=0) — void-call fix applied
- The one call WITH results (line 20: `call r17 = func#206`) uses temp r17 (valid)
- Crash is NOT OOB — program runs but prints wrong type tags

**Suggested approach**:
1. Dump func#99 JIT disassembly (dump in finalize, ELF wrap, objdump)
2. Compare memory writes: add tracing to i32.store in JIT and interpreter
   for func#99, focusing on stores to the interface type-tag addresses
3. Focus on operations around IR lines 60-70 (i64.store with spill-only vregs)
   and the control flow between lines 57-79
4. Check if scratch register (x8) management is correct for consecutive
   spill-only vreg operations

### Then: func#154 crash (tinygo_hello)

func#154 (12 regs) causes "type assert failed" → unreachable. Separate bug.
Skipping func#154 avoids the crash but does not fix the type confusion (func#99).

### Lower priority

- `tinygo_sort`: sort result `false` instead of `true` — may be same root cause
- `rust_file_io`: output diff, needs investigation
- W42: `go_math_big` wasmtime compat diff (not JIT-related)

### Completed in Phase 20

| Fix                                              | Impact                    |
|--------------------------------------------------|---------------------------|
| void-call reloadVreg (ARM64 + x86)               | +5 Mac programs           |
| ARM64 emitMemFill/emitMemCopy/emitMemGrow ABI    | ARM64 memory ops          |

### Open Work Items

| Item     | Description                                       | Status       |
|----------|---------------------------------------------------|--------------|
| W41      | JIT real-world correctness (4 Mac, 2 Ubuntu left) | **Next**     |
| W42      | wasmtime 互換性差異 (go_math_big, Mac)             | Low priority |
| Phase 18 | Lazy Compilation + CLI Extensions                 | Future       |

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
