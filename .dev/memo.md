# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5 complete. **v1.3.0 released** (tagged 7570170).
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip). E2E: 792/792 (100.0%, 0 leak).
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64. Size: 1.20MB stripped. RSS: 4.48MB.
- Module cache: `zwasm run --cache`, `zwasm compile` (D124).
- **C API**: `libzwasm.so`/`.dylib`/`.a` — 25 exported `zwasm_*` functions (D126).
- **Conditional compilation**: `-Djit=false`, `-Dcomponent=false`, `-Dwat=false` (D127).
  Minimal build: ~940KB stripped (24% reduction).
- **Phase 8 merged to main** (d770bfe). Real-world compat: 50/50 (Mac+Ubuntu).
- **main = stable**: v1.3.0 tagged. ClojureWasm updated to v1.3.0.

## Current Task

**Phase 11: Allocator Injection + Embedding (D128)**

Plan documented. Implementation not started. Design: `@./.dev/references/allocator-injection-plan.md`.

Order:
1. **11.1** CW finalizer — add `deinit()` in CW gc.zig sweep for wasm_module (ClojureWasm repo)
2. **11.2** C API config — `zwasm_config_t` + `set_allocator()` + `new_configured()` (zwasm repo)
3. **11.3** Docs — ARCHITECTURE.md allocator flow, `docs/embedding.md`, book chapter

Start with 11.1 (CW side, independent) or 11.2 (zwasm side, independent) — either order works.

## References

- `@./.dev/roadmap.md` (future phases), `@./.dev/roadmap-archive.md` (completed stages)
- `@./private/future/03_zwasm_clojurewasm_roadmap_ja.md` (integrated roadmap)
- `@./.dev/references/allocator-injection-plan.md` (Phase 11 design + tasks)
- `@./.dev/decisions.md`, `@./.dev/checklist.md`, `@./.dev/spec-support.md`
- `@./.dev/jit-debugging.md`, `@./.dev/bench-strategy.md`
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
