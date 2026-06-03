# Phase 13 — wasm-c-api surface gap list (§13.1)

> **Doc-state**: ACTIVE

Audit of `include/wasm.h` (~135 `wasm_*` functions) vs the implemented surface.
Drives §13.2 (implement missing, category-by-category). Implementations live in
`src/api/{instance,vec,trap_surface,wasi}.zig`; `src/api/wasm.zig` is the re-export hub.

**Status: 54/135 implemented (~40%); 81 missing.** (ADR-0004 pins upstream wasm-c-api
`9d6b9376`; ADR-0007 split api/wasi re-export.)

## Category breakdown

| Category | Impl | Missing | Status |
|---|---|---|---|
| Engine/Store | engine_new, store_new | config_new, engine_new_with_config | partial |
| **Type constructors** | — | valtype/functype/globaltype/tabletype/memorytype/tagtype `_new` (6) | **ABSENT** |
| **Type queries** | — | valtype_kind, functype_params/results, globaltype_content/mutability, tabletype_element/limits, memorytype_limits (9) | **ABSENT** |
| **Externtype conversions** | — | externtype_kind + as_func/global/table/memory[type] +const (≈10) | **ABSENT** |
| **Import/Export types** | — | importtype_new/module/name/type, exporttype_new/name/type (7) | **ABSENT** |
| **Frames** | — | frame_copy/instance/func_index/func_offset/module_offset (5) | **ABSENT** |
| **Foreign** | — | foreign_new (1) | **ABSENT** |
| Funcs | func_call | func_new[_with_env], func_type, func_param/result_arity, func_as_extern[_const] (7) | partial |
| Globals | global_get/set | global_new, global_type, global_as_extern[_const] (4) | partial |
| Tables | table_get/set/size/grow | table_new, table_type, table_as_extern[_const] (4) | partial |
| Memory | memory_data/data_size/size/grow | memory_new, memory_type, memory_as_extern[_const] (4) | partial |
| Extern | extern_as_{func,global,table,memory}, extern_kind, extern_vec | extern_type, extern_as_*_const (5) | partial |
| Traps | trap_new/delete/message | trap_origin, trap_trace (2) | partial |
| Modules | module_new/validate/delete | module_imports/exports, module_serialize/deserialize (4) | partial |
| Instances | instance_new/delete/exports | — | complete |
| Vec boilerplate | byte/val/extern (13) | valtype/importtype/exporttype vec ops (~10) | partial |

## §13.2 work order (by dependency)

1. **Type constructors + queries** (load-bearing — `func_new`/`global_new`/`table_new`/
   `memory_new` all consume `*type` objects): valtype, functype, globaltype, tabletype,
   memorytype (+ tagtype) `_new`/`_delete`/`_copy` + the query accessors + their vecs.
2. **Externtype + import/export types** (module_imports/exports return these).
3. **`_new` constructors for func/global/table/memory** (depend on #1).
4. **Frames + foreign + trap_origin/trace** (trap introspection).
5. **module_imports/exports/serialize/deserialize**; **`*_as_extern[_const]`** + const conversions.

## wasi.h / zwasm.h (§13.3)

- `include/wasi.h` (9 declared, 3 impl): missing `inherit_argv/env/stdio`, `set_args/envs`,
  `preopen_dir` (6 config builders).
- `include/zwasm.h`: placeholder (6 lines) — zwasm extensions TBD.

## Conformance harness (§13.4)

`test/c_api_conformance/` does NOT exist. Current C-API testing = in-source Zig test blocks
(`src/api/instance.zig`, 31 blocks per D-139) + `cli/run.zig` in-process drive. §13.4 needs a
C-linkage host test (wasmtime example port).
