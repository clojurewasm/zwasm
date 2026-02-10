# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction** — not yet started
- Opcode coverage: 225 core + 236 SIMD = 461 (from CW src/wasm/)
- WASI syscalls: ~25 (from CW)
- Spec test pass rate: TBD (no wast runner yet)
- Source: extracted from ClojureWasm `src/wasm/` (~11K LOC)

## Strategic Position

Zig-native embeddable Wasm runtime. Target niche: small, fast, zero-dependency.
Position: "wasm3 spiritual successor in Zig" — not competing with wasmtime on JIT.

## Task Queue

Stage 0: API Design & Extraction

1. [ ] 0.1: CW dependency audit — identify all CW-specific imports in src/wasm/
2. [ ] 0.2: Design public API (Engine/Module/Instance pattern)
3. [ ] 0.3: Extract source files from CW src/wasm/ → zwasm src/
4. [ ] 0.4: Remove CW dependencies (Value, GC, Env references)
5. [ ] 0.5: build.zig + build.zig.zon setup
6. [ ] 0.6: Basic test suite (load module, call function, memory ops)
7. [ ] 0.7: First benchmark (fib wasm, compare with CW embedded)
8. [ ] 0.8: CW integration — use zwasm as dependency via build.zig.zon

## Current Task

(Not started — infrastructure setup in progress)

## Previous Task

(None)

## Known Issues

- (none)

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

### Cross-project references

| Source                | Location                                                      | Purpose                          |
|-----------------------|---------------------------------------------------------------|----------------------------------|
| CW wasm source        | `/Users/shota.508/Documents/MyProducts/ClojureWasm/src/wasm/` | Extraction origin                |
| CW CLAUDE.md          | `/Users/shota.508/Documents/MyProducts/ClojureWasm/.claude/CLAUDE.md` | zwasm commit gate, workflow |
| WasmResearch docs     | `/Users/shota.508/Documents/MyProducts/WasmResearch/docs/`    | Spec analysis, proposal notes    |
| zware reference impl  | `/Users/shota.508/Documents/OSS/zware/`                       | Alternative Zig Wasm impl        |
| Zig tips              | `/Users/shota.508/Documents/MyProducts/ClojureWasm/.claude/references/zig-tips.md` | Zig 0.15.2 pitfalls |
| CW wasm benchmarks    | `/Users/shota.508/Documents/MyProducts/ClojureWasm/bench/wasm_bench.sh` | Baseline measurements |

## Handover Notes

- zwasm is a standalone extraction of CW's src/wasm/ (~11K LOC)
- Repo: `clojurewasm/zwasm` (private), cloned at `/Users/shota.508/Documents/MyProducts/zwasm`
- No CLAUDE.md in zwasm repo — workflow instructions live in CW's CLAUDE.md
- Session memory entry point: CW MEMORY.md "zwasm Project" section
