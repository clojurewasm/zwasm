# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction** — task 0.1 complete (dependency audit)
- Opcode coverage: 225 core + 236 SIMD = 461 (from CW src/wasm/)
- WASI syscalls: ~25 (from CW)
- Spec test pass rate: TBD (no wast runner yet)
- Source: extracted from ClojureWasm `src/wasm/` (~11K LOC)

## Strategic Position

Zig-native embeddable Wasm runtime. Target niche: small, fast, zero-dependency.
Position: "wasm3 spiritual successor in Zig" — not competing with wasmtime on JIT.

## Task Queue

Stage 0: API Design & Extraction

1. [x] 0.1: CW dependency audit — identify all CW-specific imports in src/wasm/
2. [ ] 0.2: Design public API (Engine/Module/Instance pattern)
3. [ ] 0.3: Extract source files from CW src/wasm/ → zwasm src/
4. [ ] 0.4: Remove CW dependencies (Value, GC, Env references)
5. [ ] 0.5: build.zig + build.zig.zon setup
6. [ ] 0.6: Basic test suite (load module, call function, memory ops)
7. [ ] 0.7: First benchmark (fib wasm, compare with CW embedded)
8. [ ] 0.8: CW integration — use zwasm as dependency via build.zig.zon

## Current Task

0.2: Design public API (Engine/Module/Instance pattern).
Define zwasm-native types to replace CW Value in the public interface.
Key: imports map, host functions, return values need zwasm-native representations.

## Previous Task

0.1: CW dependency audit — COMPLETE. Results:

### Dependency Map (11,183 LOC total)

**Clean files (0 CW deps) — extract as-is (10 files, 9,780 LOC)**:

| File           | LOC  | Internal deps                                |
|----------------|------|----------------------------------------------|
| opcode.zig     | 822  | std                                          |
| leb128.zig     | 282  | std                                          |
| predecode.zig  | 452  | std, leb128                                  |
| wit_parser.zig | 451  | std                                          |
| memory.zig     | 320  | std                                          |
| store.zig      | 528  | std, memory, opcode, vm, predecode           |
| instance.zig   | 473  | std, leb128, opcode, store, wasi, memory, module |
| module.zig     | 931  | std, leb128, opcode                          |
| wasi.zig       | 1548 | std, vm, memory, store, module, instance, opcode |
| vm.zig         | 3973 | std, leb128, opcode, store, memory, module, instance, predecode |

**CW-dependent (1 file, 891 LOC) — types.zig**:

| Import                      | Lines    | Usage                                       |
|-----------------------------|----------|---------------------------------------------|
| `../runtime/value.zig`      | L316     | valueToWasm, wasmToValue, Value params      |
| `../runtime/bootstrap.zig`  | L350     | callFnVal (host function callbacks)         |
| `../runtime/collections.zig`| L726+    | PersistentArrayMap (imports map, tests only) |

CW Value used in: WasmFn.call(), loadWithImports(), lookupImportFn(),
lookupImportSource(), valueToWasm(), wasmToValue(), HostContext, host callbacks.
Also in tests for building import maps.

**CW-only — do NOT extract (1 file, 512 LOC)**:

| File         | LOC | Deps                                    |
|--------------|-----|-----------------------------------------|
| builtins.zig | 512 | Value, var.zig, error.zig, collections  |

### Extraction Strategy

1. types.zig needs refactoring: split into zwasm-pure + CW bridge
2. Value-dependent functions become the "host callback" interface
3. Import maps: replace CW PersistentArrayMap with zwasm-native lookup
4. builtins.zig stays in CW (bridge layer)

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
