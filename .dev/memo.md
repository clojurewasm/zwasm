# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4 — COMPLETE
- Source: ~15K LOC, 16 files, 155 tests all pass
- Opcode: 225 core + 236 SIMD = 461, WASI: ~27
- Spec: 30,666/30,703 (99.9%), E2E: 180/181 (99.4%), CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.2.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.

## Task Queue

Stage 5E: E2E Test Porting & Compliance (correctness phase before optimization)

1. [x] 5E.1: Infrastructure — compliance.yaml, e2e scripts, run_spec.py --dir
2. [x] 5E.2: Batch 1 — Core MVP & Traps (25 files, 78/87 pass)
3. [x] 5E.3: Batch 2 — Float & Reference Types (15 files, all pass)
4. [x] 5E.4: Batch 3 — Programs & Regressions (14 files, all pass)
5. [x] 5E.5: Batch 4 — SIMD (14 files, all pass)
6. [x] 5E.6: Final compliance update

Stage 5 (resumed after 5E): JIT Coverage Expansion

**Target: ALL benchmarks within 2x of wasmtime (ideal: 1x).**

Final results (5.7, hyperfine 3-run, zwasm vs wasmtime):
20/21 benchmarks within 2x. 9 benchmarks FASTER than wasmtime.
Only st_matrix (3.1x) exceeds 2x — needs Stage 6 liveness regalloc.
Worst ratios: st_matrix 3.1x, st_fib2 1.95x, tgo_mfr 1.69x, fib 1.72x.
Best wins: tgo_arith 0.30x, tgo_gcd 0.33x, tgo_fib_loop 0.33x, nqueens 0.38x.

1. [x] 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
2. [x] 5.2: Close remaining gaps (st_sieve/matrix regIR opcode coverage)
3. [x] 5.3: f64/f32 ARM64 JIT — nbody 133→60ms (2.2x speedup)
4. [x] 5.4: Re-record cross-runtime benchmarks
5. [x] 5.5: JIT memory ops + call_indirect + popcnt + reload ordering fix
6. [x] 5.6: Profile and optimize remaining gaps
7. [x] 5.7: Re-record benchmarks, verify exit criteria

Stage 5F: E2E & Spec Compliance Completion

Remaining failures:
- E2E: 3 failures (table_copy_on_imported_tables ×2, partial-init-table-segment ×1)
- Spec: 40 failures (table_size64 ×36, memory_grow64 ×1, memory_trap ×1,
  memory_trap64 ×1, names ×1)

1. [x] 5F.1: Fix memory_trap + names spec failures (3 spec fixes: 30663→30666)
2. [x] 5F.2: Fix W9 transitive import chains (2 E2E failures → 0)
W10 (partial-init-table-segment, 1 E2E failure): Deferred — requires
store-independent funcref design. Shared table entries point to importing
module's store which is freed on instantiation failure.

memory64 table ops (37 spec failures): Deferred — proposal-level feature.
Needs 64-bit table limit decoding, i64 table.size/grow. See checklist W18.

Target: E2E 181/181 (100%), Spec ≥30,701/30,703 (99.99%).

Stage 6: Bug Fixes & Stability

1. [x] 6.1: Fix JIT prologue caller-saved register corruption (mfr i64 bug)
2. [ ] 6.2: Investigate remaining active bugs (#3 array pointer, #4 regir hang)
3. [ ] 6.3: Update checklist (resolve W9, clean up active bugs)

## Current Task

6.2: Investigate remaining active bugs.

## Previous Task

6.1: Fixed JIT emitPrologue loading vregs before BLR call to jitGetMemInfo,
which trashed caller-saved regs (x2-x7, x9-x15). Moved vreg loading after
the BLR. mfr benchmark now produces correct results for all iteration counts.

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
