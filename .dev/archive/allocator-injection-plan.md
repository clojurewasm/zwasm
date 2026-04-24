> **Archived 2026-04-25.** Phase 11 (allocator injection) completed
> with v1.5.0 (merge commit `49f99e5`). Preserved for historical
> reference; D128 in `.dev/decisions.md` captures the resulting
> invariant.

# Allocator Injection & Embedding Plan (D128)

Design reference for Phase 11. Read before starting implementation.

## Problem

When a GC-managed host (ClojureWasm) embeds zwasm, two independent memory
management systems coexist. The host GC collects wrapper objects but cannot
reach zwasm's internal allocations (Store, GcHeap arena, Module, VM).
This causes memory leaks when wasm modules are garbage-collected by the host.

## Current Architecture

```
User allocator
  └─ WasmModule.load(alloc, bytes)
       ├─ Store.init(alloc)
       │    ├─ GcHeap.init(alloc)       ← WasmGC objects (arena bump)
       │    └─ TypeRegistry.init(alloc)
       ├─ Module.init(alloc, bytes)     ← parsed sections
       ├─ Instance.init(alloc, ...)     ← address mappings
       └─ Vm.init(alloc)               ← execution state
```

Zig API already accepts `std.mem.Allocator` — no changes needed for Zig hosts.
C API creates per-module GPA internally — no allocator injection point.

## Three Embedding Patterns

| Pattern                  | Allocator              | GC            | Gap                         |
|--------------------------|------------------------|---------------|-----------------------------|
| CLI (standalone)         | page_allocator / GPA   | zwasm arena   | None                        |
| Zig host (CW)            | host-provided allocator | dual-GC       | Finalizer missing in CW     |
| C host (FFI)             | malloc/free or default | host-dependent | No inject point in C API    |

## Tasks

### 11.1 CW Finalizer (ClojureWasm side, highest priority)

**Problem**: CW GC sweeps `WasmModule` wrapper but never calls `deinit()` on
the inner `zwasm.WasmModule`. All zwasm-internal memory leaks.

**Fix**: Add finalizer in CW `gc.zig` sweep phase:

```zig
// In sweep, when freeing a wasm_module tagged Value:
.wasm_module => {
    val.asWasmModule().deinit();  // releases zwasm Store, Module, VM, GcHeap
},
```

**Why not inject CW's GC allocator into zwasm?**
- zwasm internal structures are opaque — CW GC cannot trace them
- If CW GC sweeps zwasm's VM mid-execution → segfault
- `smp_allocator` (non-GC, thread-safe) + finalizer is the safe pattern

**Files**: `ClojureWasm/src/runtime/gc.zig`, `ClojureWasm/src/runtime/wasm_types.zig`

**Tests**: Verify no leak via repeated load/GC cycle in a test program.

### 11.2 C API Config + Allocator Injection (zwasm side)

**New types**:

```c
typedef struct zwasm_config_t zwasm_config_t;

typedef void *(*zwasm_alloc_fn_t)(void *ctx, size_t size, size_t alignment);
typedef void (*zwasm_free_fn_t)(void *ctx, void *ptr, size_t size, size_t alignment);

zwasm_config_t *zwasm_config_new(void);
void zwasm_config_delete(zwasm_config_t *config);
void zwasm_config_set_allocator(zwasm_config_t *config,
    zwasm_alloc_fn_t alloc_fn,
    zwasm_free_fn_t free_fn,
    void *ctx);

// Extended creation (backward compatible — NULL config = default GPA)
zwasm_module_t *zwasm_module_new_configured(const uint8_t *wasm_ptr, size_t len,
                                             zwasm_config_t *config);
zwasm_module_t *zwasm_module_new_wasi_configured2(const uint8_t *wasm_ptr, size_t len,
                                                    zwasm_wasi_config_t *wasi_config,
                                                    zwasm_config_t *config);
```

**Zig implementation**: Wrap C function pointers as `std.mem.Allocator`:

```zig
const CAllocator = struct {
    alloc_fn: zwasm_alloc_fn_t,
    free_fn: zwasm_free_fn_t,
    ctx: ?*anyopaque,

    fn allocator(self: *CAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    // vtable: alloc delegates to alloc_fn, free delegates to free_fn
};
```

**Scope**: Allocator injection covers zwasm internal bookkeeping only.
Wasm linear memory (memory.grow) remains separately managed per Wasm spec.

**Precedents**: SQLite (`SQLITE_CONFIG_MALLOC`), Lua (`lua_newstate(alloc_fn, ud)`).

**Files**: `src/c_api.zig`, `include/zwasm.h`

**Tests**: `test/c_api/test_custom_alloc.c` — inject counting allocator, verify
all allocs freed on `zwasm_module_delete`.

### 11.3 Documentation — Allocator Flow + Embedding Guide

**11.3a ARCHITECTURE.md update**
- Add allocator flow diagram (see "Current Architecture" above)
- Add "Embedding" section explaining the three patterns

**11.3b docs/embedding.md (new)**
- Zig embedding: `WasmModule.load(my_allocator, bytes)`, lifecycle ownership
- C embedding: `zwasm_config_set_allocator()`, NULL = default
- GC host pattern: non-GC allocator + finalizer (CW pattern as example)
- Language examples: Python (ctypes + `PyMem_Malloc`), Go (cgo)
- WasmGC ref types: current limitation (i32/i64/f32/f64 only at API boundary)

**11.3c Book chapter (Phase 18 integration)**
- `book/en/embedding.md` / `book/ja/embedding.md`
- Include allocator injection tutorial

**Files**: `ARCHITECTURE.md`, `docs/embedding.md`, `book/`

### 11.4 WasmGC Ref Type Exposure (future, after 11.1-11.3)

Currently CW filters out `funcref`/`externref` at the API boundary.
Future work to bridge WasmGC objects with host GC:

- `externref` → host Value stored in zwasm GcHeap externref table
- `funcref` → host function reference as Wasm callable
- Requires coordinated GC roots between host and zwasm

This is independent of D128 allocator injection. Tracked separately.

## Implementation Order

| Step | Task                 | Repo       | Depends on | Effort |
|------|----------------------|------------|------------|--------|
| 1    | 11.1 CW finalizer     | ClojureWasm | —          | Small  |
| 2    | 11.2 C API config     | zwasm      | —          | Medium |
| 3    | 11.3a ARCHITECTURE.md | zwasm      | 11.2       | Small  |
| 4    | 11.3b embedding.md    | zwasm      | 11.2       | Medium |
| 5    | 11.3c Book chapter    | zwasm      | 11.3b      | Medium |
| 6    | 11.4 Ref type bridge  | Both       | 11.1, 11.2 | Large  |

Steps 1 and 2 are independent — can be done in parallel or either order.
Steps 3-5 are documentation and can follow at any time after step 2.
Step 6 is future work (tracked in roadmap Future section).

## Decision Record

D128 in `decisions.md` covers the architectural rationale.
This file covers implementation details and task breakdown.
