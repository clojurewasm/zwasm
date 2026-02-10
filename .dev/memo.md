# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- Source: 10,398 LOC, 11 files, 115 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 544ms (ReleaseSafe, CLI)
- vs wasmtime JIT: 58ms (9.4x gap — interpreter vs JIT)
- Spec test pass rate: TBD (no wast runner yet)

## Strategic Position

**zwasm is an independent Zig WebAssembly runtime — library AND CLI tool.**

- NOT a ClojureWasm subproject. CW is just one potential consumer.
- Two delivery modes: `@import("zwasm")` library + `zwasm` CLI (like wasmtime)
- Benchmark target: **wasmtime** (measure gap, close it with JIT)
- Optimization target: ARM64 Mac first, x86_64 later
- Position: smallest, fastest Zig-native Wasm runtime

**IMPORTANT**: Do NOT make design decisions based on CW's needs.
Design for the Zig ecosystem. CW adapts to zwasm's API, not the reverse.

## Task Queue

Stage 1: Library Quality + CLI Polish

1. [x] 1.1: build.zig.zon (package metadata for Zig package manager)
2. [x] 1.2: Structured error types (W3 — already resolved, no EvalError remains)
3. [ ] 1.3: Public API doc comments (types.zig comprehensive documentation)
4. [ ] 1.4: CLI `zwasm run` WASI args/env/preopen support
5. [ ] 1.5: CLI exit code propagation from WASI modules
6. [ ] 1.6: Example programs (examples/ directory with standalone .zig files)
7. [ ] 1.7: `zwasm inspect --json` machine-readable output

Stage 2 (planned): Spec Conformance + wast test runner
Stage 3 (planned): JIT (ARM64) + Optimization

## Current Task

1.3: Public API doc comments — comprehensive documentation for types.zig.
All public types, functions, and fields get doc comments.

## Previous Task

1.2: W3 checked — no EvalError remains. Zig inferred error sets are appropriate.
1.1: build.zig.zon created (v0.1.0, Zig 0.15.2+).

## Known Issues

- None currently open

## Reference Chain

Session resume: read this file → follow references below.

### zwasm documents

| Topic              | Location                                          |
|--------------------|---------------------------------------------------|
| Roadmap            | `.dev/roadmap.md`                                 |
| Decisions          | `.dev/decisions.md`                               |
| Deferred items     | `.dev/checklist.md` (W## items)                   |
| Spec coverage      | `.dev/spec-support.md`                            |
| Wasm spec refs     | `.dev/references/wasm-spec.md`                    |

### External references

| Source                | Location                                                      | Purpose                      |
|-----------------------|---------------------------------------------------------------|------------------------------|
| wasmtime              | `/Users/shota.508/Documents/OSS/wasmtime/`                    | Performance target, API ref  |
| WasmResearch docs     | `/Users/shota.508/Documents/MyProducts/WasmResearch/docs/`    | Spec analysis, proposals     |
| zware reference impl  | `/Users/shota.508/Documents/OSS/zware/`                       | Alt Zig Wasm impl            |
| Zig tips              | `/Users/shota.508/Documents/MyProducts/ClojureWasm/.claude/references/zig-tips.md` | Zig 0.15.2 pitfalls |
| Wasm spec tests       | https://github.com/WebAssembly/spec/tree/main/test/core       | Conformance target           |

## Handover Notes

- zwasm is an independent Zig Wasm runtime (library + CLI)
- Originated from ClojureWasm src/wasm/ extraction, but now fully independent
- Repo: `clojurewasm/zwasm` (private)
- Workflow instructions: CW `.claude/CLAUDE.md` → "zwasm Development" section
- Session memory: CW MEMORY.md "zwasm Project" section
- **Design principle**: zwasm serves the Zig ecosystem, not CW specifically
