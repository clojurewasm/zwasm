# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-11 — COMPLETE
- Source: ~15K LOC, 17 files, 169 tests all pass
- Opcode: 234 core + 236 SIMD = 470, WASI: ~27
- Spec: 30,704/30,704 (100%), E2E: 297/298 (99.7%), CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.7.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.

## Completed Stages

Stages 0-7, 5E, 5F, 8-11 — all COMPLETE. See `roadmap.md` for details.
Key results: Spec 30,704/30,704 (100%), E2E 297/298, 20/21 bench < 2x wasmtime.

## Task Queue

**Execution order: C1 → C2 → C3 → C4 → D → B → A**
(Memory64 tables → Exception handling → Wide arithmetic → Custom page sizes
→ Security → WAT parser → x86_64 JIT)

Stage 7: Memory64 Table Operations (W18)

Target: Fix 37 spec failures (table_size64 ×36, memory_grow64 ×1).

1. [x] 7.1: Table type addrtype decoding (module.zig, limits flag 0x04-0x07)
2. [x] 7.2: table.size/grow i64 variants (vm.zig)
3. [x] 7.3: Table instruction validation for i64 indices (call_indirect table64)
4. [x] 7.4: Spec test verification + compliance update

Stage 8: Exception Handling (W13)

Target: tag section, try_table, throw, throw_ref, exnref.

1. [x] 8.1: Tag section parsing + exnref type (module.zig, opcode.zig)
2. [x] 8.2: throw / throw_ref instructions (vm.zig)
3. [x] 8.3: try_table + catch clauses (vm.zig, predecode.zig)
4. [x] 8.4: Exception propagation across call stack
5. [x] 8.5: Spec test verification + compliance update
6. [x] 8.6: JIT exception awareness (fallback or landing pads)

Stage 9: Wide Arithmetic (W14)

Target: 4 opcodes — i64.add128, sub128, mul_wide_s/u.

1. [x] 9.1: Opcode decoding + validation
2. [x] 9.2: Instruction handlers (multi-value i128)
3. [x] 9.3: Spec test verification

Stage 10: Custom Page Sizes (W15)

Target: Non-64KB page sizes in memory type.

1. [x] 10.1: Memory type page_size field decoding
2. [x] 10.2: memory.size/grow adjusted for page_size
3. [x] 10.3: Spec test verification

Stage 11: Security Hardening

Target: Deny-by-default WASI, capability flags, resource limits.
Note: W^X already done (JIT finalize: mmap RW → mprotect RX).

1. [x] 11.1: Capabilities struct + deny-by-default WASI
2. [x] 11.2: CLI --allow-* flags
3. [x] 11.3: Resource limits (memory ceiling, fuel metering)
4. [x] 11.4: Import validation at instantiation

Stage 12: WAT Parser & Feature Flags (W17)

Target: `zwasm run file.wat`, build-time `-Dwat=false`.

1. [x] 12.1: Build-time feature flag system (-Dwat option in build.zig)
2. [ ] 12.2: WAT S-expression tokenizer (lexer for WAT syntax)
3. [ ] 12.3: WAT parser — module structure (module, func, memory, table, global, import, export)
4. [ ] 12.4: WAT parser — instructions (all opcodes, folded S-expr form)
5. [ ] 12.5: Wasm binary encoder (emit valid .wasm from parsed AST)
6. [ ] 12.6: WAT abbreviations (inline exports, type use, etc.)
7. [ ] 12.7: API + CLI integration (loadFromWat, auto-detect .wat)
8. [ ] 12.8: E2E verification (issue11563.wat, issue12170.wat)

Stage 13: x86_64 JIT Backend

Target: x86_64 codegen, CI on ubuntu.

(Task breakdown TBD at stage start.)

## Current Task

12.2: WAT S-expression tokenizer.

## Previous Task

12.1 complete. -Dwat build option, build_options.enable_wat, wat.zig stub, loadFromWat API, D106.

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
