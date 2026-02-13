# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-19 — COMPLETE (Wasm 3.0 all 9 proposals + GC collector + WASI P1 full)
- Source: ~33K LOC, 19 files, 239+ tests all pass
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 61,650/61,761 Mac (99.8%), incl. GC 472/546, threads 306/310, E2E: 356/356, CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.1.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.

## Completed Stages

Stages 0-7, 5E, 5F, 8-12 — all COMPLETE. See `roadmap.md` for details.
Key results: Spec 30,715/30,715 (100%), E2E 356/356 (100%, Zig runner), 20/21 bench < 2x wasmtime.

## Task Queue

**Execution order: 20 → 21 → 22A → 22B → 22C → 22D**
(features CLI → threads → component model)

Stages 7-19: ALL COMPLETE (see roadmap.md for details).

Stage 20: `zwasm features` CLI + Spec Compliance Metadata

Target: Machine-readable feature listing (~200 LOC). No runtime changes.

1. [x] 20.1: Add `zwasm features` subcommand — prints table of supported proposals with status
2. [x] 20.2: Spec level tags per feature (W3C Recommendation / Finalized / Preview / Not yet)
3. [x] 20.3: `--json` output for machine consumption

Stage 21: Threads (Shared Memory + Atomics)

Target: Core Wasm threads proposal (~1,500 LOC).
Shared memory, atomic ops, wait/notify. Phase 4, browser-shipped.
Reference: wasmtime cranelift atomics, spec repo `~/Documents/OSS/WebAssembly/threads`.

1. [x] 21.1: Shared memory flag in memory section, AtomicOpcode enum, 0xFE prefix decoder
2. [x] 21.2: All 79 atomic opcodes (load/store/rmw/cmpxchg) + alignment + shared memory checks
3. [x] 21.3: memory.atomic.wait32/wait64/notify (single-threaded semantics)
4. [x] 21.4: atomic.fence (no-op)
5. [x] 21.5: Spec tests 306/310 + runner thread/wait/either support (4 genuine multi-thread failures)

Stage 22: Component Model (W7)

Target: Full CM support. WIT parsing, Canonical ABI, component linking.
wasmtime is reference impl. Each group independently mergeable.
Design: default ON, implement all wasmtime supports, minimal flags.

Group A: WIT Parser (~800 LOC)
1. [x] A1: WIT lexer + token types
2. [x] A2: WIT parser — interfaces, worlds, types, functions
3. [x] A3: WIT resolution — use declarations, package references
4. [x] A4: Unit tests + wasmtime WIT corpus validation

Group B: Component Binary Format (~1,200 LOC)
5. [x] B1: Component section types (component, core:module, instance, alias, etc.)
6. [x] B2: Component type section — func types, component types, instance types
7. [x] B3: Canon section — lift/lower/resource ops
8. [ ] B4: Start, import, export sections
9. [ ] B5: Nested component/module instantiation

Group C: Canonical ABI (~1,500 LOC)
10. [ ] C1: Scalar types (bool, integers, float, char)
11. [ ] C2: String encoding (utf-8/utf-16/latin1+utf-16)
12. [ ] C3: List, record, tuple, variant, enum, option, result
13. [ ] C4: Flags, own/borrow handles
14. [ ] C5: Memory realloc protocol + post-return

Group D: Component Linker + WASI P2 (~2,000 LOC)
15. [ ] D1: Component instantiation — resolve imports, create instances
16. [ ] D2: Virtual adapter pattern — P1 compat shim
17. [ ] D3: WASI P2 interfaces — wasi:io, wasi:clocks, wasi:filesystem, wasi:sockets
18. [ ] D4: `zwasm run` component support (detect component vs module automatically)
19. [ ] D5: Spec tests + integration

## Current Task

Stage 22 B4: Start, import, export sections

## Previous Task

B3: Canon section — lift/lower with CanonOptions (string encoding, memory, realloc, post-return), resource.new/drop/rep, alias section (instance/core_instance/outer). 3 new tests.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests via wasm-tools 1.244.0: 472/546 (86.4%), 18 files. W21 resolved.

## Known Bugs

None. Mac 61,650/61,761 (99.8%), 4 thread-dependent failures (require real threading), 32 GC skips, 33 multi-module linking failures.
Note: Ubuntu Debug build has 11 extra timeouts on tail-call recursion tests (return_call/return_call_ref count/even/odd 1M iterations). Use ReleaseSafe for spec tests on Ubuntu.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
