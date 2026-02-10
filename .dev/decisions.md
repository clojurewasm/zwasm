# Design Decisions

Architectural decisions for zwasm. Reference by searching `## D##`.
Only architectural decisions — not bug fixes or one-time migrations.

Shares D## numbering with ClojureWasm (start from D100 to avoid conflicts).

---

## D100: Extraction from ClojureWasm

**Decision**: Extract CW `src/wasm/` as standalone library rather than rewriting.

**Rationale**:
- 11K LOC of battle-tested code (461 opcodes, SIMD, predecoded IR)
- CW has been using this code in production since Phase 35W (D84)
- Rewriting would lose optimizations (superinstructions, VM reuse, sidetable)

**Constraints**:
- Must remove all CW dependencies (Value, GC, Env, EvalError)
- Public API must be CW-agnostic (no Clojure concepts in interface)
- CW becomes a consumer via build.zig.zon dependency

---

## D101: Engine / Module / Instance API Pattern

**Decision**: Three-tier API matching Wasm spec concepts.

```
Engine  — runtime configuration, shared compilation cache
Module  — decoded + validated Wasm binary (immutable)
Instance — instantiated module with memory, tables, globals (mutable)
```

**Rationale**:
- Matches wasmtime/wasmer mental model (familiarity)
- Matches Wasm spec terminology (Module, Instance, Store)
- Clean separation: decode once → instantiate many

---

## D102: Allocator-Parameterized Design

**Decision**: All zwasm types take `std.mem.Allocator` as parameter. No global allocator.

**Rationale**:
- Follows CW's D3 (no global mutable state)
- Enables: arena allocator for short-lived modules, GPA for debugging, fixed-buffer for embedded
- Zig idiom: caller controls allocation strategy

---
