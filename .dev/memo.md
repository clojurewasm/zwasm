# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Zig toolchain**: 0.16.0 (migrated 2026-04-24).
- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, 20 complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 796/796 Mac+Ubuntu, 0 fail.
- Real-world: Mac 50/50, Ubuntu 50/50, Windows 46/46, 0 crash.
- FFI: 80/80 Mac+Ubuntu.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary stripped: Mac 1.38 MB, Linux 1.65 MB (ceiling 1.80 MB). Memory: ~3.5 MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. v1.10.0 released; post-release work on delib / W46 merged
  via PRs #47 (1a/1b pre-cursor), #48 (1b), #49 (1c/1d/1e/1f + C-API libc fix).
- link_libc = false across lib / cli / tests / examples / e2e / bench / fuzz.
  C-API targets (shared-lib, static-lib, c-test) keep link_libc = true because
  `src/c_api.zig` uses `std.heap.c_allocator`.

## Current Task

**W46 Phase 1 — DONE (2026-04-25).** PR #49 merged (`30a3680`). See
`.dev/checklist.md` Resolved section for details. Next candidate work:

- **W47**: `tgo_strops_cached` +24% regression investigation (single-benchmark,
  low priority). See checklist.
- **W45**: SIMD loop persistence — skip Q-cache eviction at loop headers
  (requires back-edge detection in `scanBranchTargets`).
- **W46 Phase 2 (optional)**: migrate `fd_read`/`fd_write` onto `std.Io`.
  Not blocking. Would help return binary size to 1.50 MB target and improve
  Windows I/O correctness further; pick up when `std.Io` stdlib APIs stabilize.

## Previous Task

**W46 Phase 1c/1d/1e/1f — DONE (2026-04-25 via PR #49).**

Routed test-site and trace-site `std.c.*` calls through new platform helpers
(`pfdDup2`, `pfdPipe`, `pfdSleepNs` added alongside existing `pfd*` family),
then flipped `.link_libc = false` across every module in `build.zig` except
the three C-API targets. CI-green on all four runners (Mac/Ubuntu/Windows/
size-matrix). Fix commit `c11a947` routed `std.c.{pipe,dup,dup2,read,
nanosleep}` in wasi.zig+vm.zig tests; `04ac19d` kept link_libc=true on
C-API targets after the first push revealed `std.heap.c_allocator` needs libc.

### Hard-won nuggets (reuse later)

- **Do NOT wrap in `nix develop --command` inside this repo.** direnv +
  claude-direnv has already loaded the flake devshell AND unset
  DEVELOPER_DIR/SDKROOT. Re-entering nix shell re-sets SDKROOT and breaks
  `/usr/bin/git`. See `memory/nix_devshell_tools.md`.
- **e2e_runner uses `init.io`, NOT a locally constructed Threaded io**.
  A fresh `std.Io.Threaded.init(allocator, .{}).io()` inside user main
  crashes with `0xaa…` in `Io.Timestamp.now` when iterating many files.
- **C-API targets must keep `link_libc = true`.** `src/c_api.zig` uses
  `std.heap.c_allocator`. Mac masks this via libSystem auto-link; Linux and
  Windows fail with "C allocator is only available when linking against libc".
- **Cross-compile sanity trick.** `zig build test -Dtarget=x86_64-linux-gnu`
  and `-Dtarget=x86_64-windows-gnu` compile cleanly on Mac even though the
  test binaries can't execute — the compile success alone catches link-time
  symbol-resolution issues before pushing to CI.

## Previous Task (older)

**W45: SIMD Loop Persistence — DONE (2026-03-26)**

Q-reg/XMM cache now persists across loop iterations. Three techniques:

1. **Loop pre-header**: pre-loads v128 input vregs into Q/XMM before pc_map entry.
   Back-edges skip pre-loads (jump to pc_map). First iteration pays LDR cost once.

2. **Flush-not-evict at back-edges**: `simdQregFlushAll()` writes dirty Q-regs
   to memory but keeps cache entries. Ensures deopt safety while preserving cache.

3. **Out-of-line flush stubs**: forward conditional branches (loop exits) use
   stubs at function end. Fall-through (hot loop path) has zero flush overhead.

### Results (2026-03-26)

| Benchmark            | Before | After   | Improvement |
|----------------------|--------|---------|-------------|
| simd_mandel (simd)   | 18.7s  | 17.23s  | 8%          |
| simd_matmul (simd)   | 2.7s   | 2.53s   | 6%          |
| simd_chain           | 390ms  | 397ms   | ~same       |
| simd_nbody (simd)    | 520ms  | 352ms   | 32%         |
| scalar benchmarks    |        |         | no regress  |

### Remaining SIMD gap

| Benchmark            | zwasm  | wasmtime | ratio  |
|----------------------|--------|----------|--------|
| simd_mandel          | 17.2s  | 240ms    | 72x    |
| simd_matmul          | 2.5s   | 20ms     | 125x   |
| simd_chain           | 397ms  | 10ms     | 40x    |
| simd_nbody           | 352ms  | 10ms     | 35x    |

### Gap analysis (2026-03-26, wasmtime Cranelift 調査)

zwasm scalar 13.8s vs wasmtime scalar 0.79s = **17x gap** (base JIT quality)
zwasm SIMD 16.7s vs wasmtime SIMD 0.23s = **74x gap** (SIMD still slower than scalar!)

| 要因               | wasmtime                          | zwasm                           | 影響 |
|--------------------|-----------------------------------|---------------------------------|------|
| 境界チェック       | Guard page で 0 命令              | CMP+Bcc 毎回（v128 含む）      | 大   |
| レジスタ常駐       | SSA + regalloc2 でブロック横断    | Q-reg キャッシュ（BB 内のみ）  | 大   |
| FMA 融合           | ISLE で mul+add → FMLA            | なし（2 命令のまま）           | 中   |
| LICM               | なし                              | なし                           | —    |

wasmtime 参照: `~/Documents/OSS/wasmtime/`
- bounds_checks.rs: 64-bit host = 4GB reservation + 32MB guard
- lower.isle (aarch64): FMLA rules, v128 bitcast = zero-cost
- regalloc2: 64 vector vregs pinned to NEON V0-V31
- **Cranelift は LICM 未実装** — GVN + ISLE 簡約のみ

### Next optimization path (ordered by impact)

1. **W46: v128 guard page path** → SIMD 境界チェック除去 (DONE 2026-03-26)
   - ARM64: all 22 SIMD memory ops now use guard page path
   - x86: already had guard page conditions (no change needed)
   - No benchmark impact — mandelbrot inner loop has 0 v128 memory ops
   - Correct and safe: reduces code size, helps memory-heavy SIMD workloads

2. **W47: FMLA instruction fusion** → mul+add → 1 ARM64 instruction
   - Detect `f32x4.mul rd,a,b` + `f32x4.add rd2,rd,c` → `FMLA Vd,Va,Vb`
   - Peephole in IR or emitSimdNativeInner
   - wasmtime: ISLE rule `(fmadd ty x y z) → FMLA`

3. **W48: Non-native SIMD → native** → reduce SCRATCH indirection
   - f32x4.le uses SCRATCH0/1 instead of Q-reg cache
   - Convert to emitSimdBinaryNeon pattern (direct Q-reg ops)
   - v128.any_true could use cached Q-reg directly

### Open Work Items

| Item       | Description                                       | Status           |
|------------|---------------------------------------------------|------------------|
| W45        | SIMD loop persistence (Q-reg across loops)        | DONE (2026-3-26) |
| W44        | SIMD register class (D132 Phase B)                | DONE (2026-3-26) |
| Phase 18   | Lazy Compilation + CLI Extensions                 | Future           |
| Zig 0.16   | API breaking changes                              | When released    |

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
| 20       | JIT Correctness Sweep                 | 2026-03-25 |

## Next Session Reference Chain

1. **Orient**: `git log --oneline -5 && git status && git branch`
2. **This memo**: current task (W44 design + implementation plan)
3. **D132 Phase B**: `@./.dev/decisions.md` → search `## D132` → "Phase B"
4. **regalloc.zig**: `RegInstr` struct, SIMD opcode handling (search `SIMD_BASE`)
5. **jit.zig**: `emitSimdBinaryOp`, `emitLoadV128`, `emitStoreV128`, `SIMD_SCRATCH0/1`
6. **x86.zig**: same patterns as jit.zig
7. **Reference impl**: wasmtime cranelift (`~/Documents/OSS/wasmtime/`) — SIMD register allocation
8. **SIMD benchmarks**: `bench/run_simd_bench.sh` — A/B comparison
9. **Ubuntu testing**: `@./.dev/references/ubuntu-testing-guide.md`
10. **Merge gate**: CLAUDE.md → "Merge Gate Checklist" section

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — resolved work items
- `@./.dev/decisions.md` — D130 (SIMD arch), D132 (SIMD perf plan)
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `@./.dev/references/w38-osr-research.md` — OSR research
- `bench/simd_comparison.yaml` — SIMD performance data
- `bench/history.yaml` — benchmark history (latest: phase20-rem-fix)
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
