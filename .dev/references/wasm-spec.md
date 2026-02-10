# Wasm/WASI Spec References

Quick reference for spec URLs and cross-project knowledge sources.

## Official Specifications

| Spec                    | URL                                                      |
|-------------------------|----------------------------------------------------------|
| WebAssembly Core 2.0    | https://webassembly.github.io/spec/core/                 |
| WASI Preview 1          | https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md |
| WASI Preview 2          | https://github.com/WebAssembly/WASI/tree/main/wasip2     |
| Component Model         | https://github.com/WebAssembly/component-model           |
| Proposals overview      | https://github.com/WebAssembly/proposals                 |
| Spec test suite         | https://github.com/WebAssembly/spec/tree/main/test/core  |

## Cross-Project References

### WasmResearch (local analysis docs)

Path: `/Users/shota.508/Documents/MyProducts/WasmResearch/docs/`

Contains detailed analysis of Wasm proposals, WASI design, and implementation notes.

### zware (alternative Zig Wasm impl)

Path: `/Users/shota.508/Documents/OSS/zware/`

- Reference for Zig-idiomatic Wasm patterns
- MVP only (no SIMD, no predecoded IR)
- Useful for API design comparison

### ClojureWasm source (extraction origin)

Path: `/Users/shota.508/Documents/MyProducts/ClojureWasm/src/wasm/`

Key files:
- `module.zig` — Wasm binary decoding, validation
- `vm.zig` — Instruction execution engine
- `instance.zig` — Module instantiation
- `types.zig` — Wasm type definitions
- `predecode.zig` — Fixed-width IR transformation
- `opcode.zig` — Opcode enum (461 entries)
- `store.zig` — Memory, table, global management
- `memory.zig` — Linear memory implementation
- `wasi.zig` — WASI Preview 1 syscalls
- `wit_parser.zig` — WIT interface parser

CW-specific (do NOT extract):
- `builtins.zig` — CW Value ↔ Wasm bridge (stays in CW)

### CW Optimization History

Path: `/Users/shota.508/Documents/MyProducts/ClojureWasm/.dev/optimizations.md`

Documents all optimizations applied to the Wasm interpreter:
- D86: VM reuse (7.9x improvement)
- D86: Sidetable lazy branch resolution (1.44x)
- Superinstructions (11 fused opcodes)
- Predecoded IR (fixed-width format)

### CW Wasm Benchmarks

- Script: `/Users/shota.508/Documents/MyProducts/ClojureWasm/bench/wasm_bench.sh`
- History: `/Users/shota.508/Documents/MyProducts/ClojureWasm/bench/wasm_history.yaml`
- TinyGo sources: `/Users/shota.508/Documents/MyProducts/ClojureWasm/bench/wasm/*.go`

### Zig Development Tips

Path: `/Users/shota.508/Documents/MyProducts/ClojureWasm/.claude/references/zig-tips.md`

Zig 0.15.2 pitfalls and idioms. Read before writing Zig code.
