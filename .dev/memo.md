# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4 — COMPLETE
- Source: ~15K LOC, 16 files, 155 tests all pass
- Opcode: 225 core + 236 SIMD = 461, WASI: ~27
- Spec: 30,703/30,703 (100%), E2E: 180/181 (99.4%), CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.2.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.

## Completed Stages

Stages 0-6, 5E, 5F — all COMPLETE. See `roadmap.md` for details.
Key results: Spec 30,666/30,703 (99.9%), E2E 180/181, 20/21 bench < 2x wasmtime.

## Task Queue

**Execution order: C1 → C2 → C3 → C4 → D → B → A**
(Memory64 tables → Exception handling → Wide arithmetic → Custom page sizes
→ Security → WAT parser → x86_64 JIT)

Stage 7: Memory64 Table Operations (W18)

Target: Fix 37 spec failures (table_size64 ×36, memory_grow64 ×1).

1. [x] 7.1: Table type addrtype decoding (module.zig, limits flag 0x04-0x07)
2. [x] 7.2: table.size/grow i64 variants (vm.zig)
3. [x] 7.3: Table instruction validation for i64 indices (call_indirect table64)
4. [ ] 7.4: Spec test verification + compliance update

Stage 8: Exception Handling (W13)

Target: tag section, try_table, throw, throw_ref, exnref.

1. [ ] 8.1: Tag section parsing + exnref type (module.zig, opcode.zig)
2. [ ] 8.2: throw / throw_ref instructions (vm.zig)
3. [ ] 8.3: try_table + catch clauses (vm.zig, predecode.zig)
4. [ ] 8.4: Exception propagation across call stack
5. [ ] 8.5: Spec test verification + compliance update
6. [ ] 8.6: JIT exception awareness (fallback or landing pads)

Stage 9: Wide Arithmetic (W14)

Target: 4 opcodes — i64.add128, sub128, mul_wide_s/u.

1. [ ] 9.1: Opcode decoding + validation
2. [ ] 9.2: Instruction handlers (multi-value i128)
3. [ ] 9.3: Spec test verification

Stage 10: Custom Page Sizes (W15)

Target: Non-64KB page sizes in memory type.

1. [ ] 10.1: Memory type page_size field decoding
2. [ ] 10.2: memory.size/grow adjusted for page_size
3. [ ] 10.3: Spec test verification

Stage 11: Security Hardening

Target: Deny-by-default WASI, capability flags, W^X, resource limits.

(Task breakdown TBD at stage start — requires design investigation.)

Stage 12: WAT Parser & Feature Flags (W17)

Target: `zwasm run file.wat`, build-time `-Dwat=false`.

(Task breakdown TBD at stage start.)

Stage 13: x86_64 JIT Backend

Target: x86_64 codegen, CI on ubuntu.

(Task breakdown TBD at stage start.)

## Current Task

Stage 7.4: Spec test verification + compliance update.

## Previous Task

7.3: Fixed call_indirect to pop i64 table index for table64 tables.
No separate predecode validation needed (type correctness in interpreter).

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
