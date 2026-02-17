# WAT Parser Gap Triage Report

Generated from `run_spec.py --wat-mode --summary` audit.

## Summary

| Metric | Value |
|--------|-------|
| Binary mode | 62,158/62,158 (100.0%) |
| WAT mode | 56,624/62,196 (91.0%) |
| WAT failures | 5,572 |
| WAT conversion failures | 708 (intentionally malformed binaries) |
| Fixable test delta | ~5,572 assertions across 121 files |

## Failure Breakdown by Category

| # | Category | Failures | Files | Root Cause | Priority |
|---|----------|----------|-------|------------|----------|
| 1 | **CORE** | 2,754 | 65 | `(type N)` on block/if/loop; multi-value block types | HIGH |
| 2 | **MEM64** | 1,503 | 17 | `(memory i64 N)` syntax not parsed | HIGH |
| 3 | **GC** | 508 | 24 | `(ref $T)`, `(rec ...)`, `(sub ...)` heap types | MED (W30) |
| 4 | **NAMES** | 460 | 1 | FunctionIndexOutOfBounds with many exports | MED |
| 5 | **SIMD** | 288 | 2 | simd_lane/simd_const edge cases | MED |
| 6 | **EH** | 48 | 3 | OutOfMemory on try_table/throw (W33) | LOW |
| 7 | **THREADS** | 11 | 9 | `shared` memory flag not parsed | LOW |

Total: 5,572 failures across 121 files.

## Category Details

### 1. CORE — Block Type References (2,754 failures, 65 files)

**Root cause**: `wasm-tools print` outputs `(block (type N) (result T1 T2) ...)` for
multi-value blocks. The zwasm WAT parser (`src/wat.zig`) only supports
`block_type: ?WatValType` — a single optional return type.

**Affected syntax**:
- `(block (type N) ...)` — type-indexed block
- `(if (type N) ...)` — type-indexed if
- `(loop (type N) ...)` — type-indexed loop
- Multi-value results: `(result i32 i32)` on block/if/loop

**Affected files** (top by failure count):
- table_copy: 443, table_copy64: 443, br_table: 161, select: 118,
  call_indirect: 114, if: 123, func: 96, left-to-right: 95,
  block: 52, nop: 83, loop: 77, br: 76, br_if: 88, call: 69,
  return: 63, local_tee: 55, load: 37, ...

**Fix approach**: Extend WAT parser to accept `(type N)` syntax on block/if/loop.
Parse type index, look up signature in type section, use as block type.
For multi-value `(result T1 T2 ...)`, create or find matching type entry.

### 2. MEM64 — Memory64 Index Type (1,503 failures, 17 files)

**Root cause**: `wasm-tools print` outputs `(memory i64 N)` for 64-bit memories.
The WAT parser doesn't recognize `i64` as a memory index type keyword.

**Affected syntax**:
- `(memory i64 N)` — 64-bit indexed memory
- `(memory i64 N M)` — 64-bit indexed memory with max

**Affected files**: endianness64, memory_copy64, memory_fill64, memory_init64,
memory_grow64, address0, address1, load0-2, store0-2, float_memory0,
float_exprs0-1, data_drop0, memory_redundancy64, etc.

**Fix approach**: In memory declaration parsing, check for `i64` token before
the initial/max page count. Set `is_memory64 = true` flag.

### 3. GC — Reference Types and Recursive Types (508 failures, 24 files)

**Root cause**: GC proposal syntax for heap types, recursive type groups, and
subtyping not fully supported. This is the known W30 checklist item.

**Affected syntax**:
- `(ref $T)` / `(ref null $T)` — typed references
- `(rec ...)` — recursive type groups
- `(sub ...)` / `(sub final ...)` — subtype declarations
- `(struct ...)` / `(array ...)` type definitions
- `ref.cast (ref $T)` — cast with type annotation

**Affected files**: array, array_copy, array_fill, array_init_data/elem,
array_new_data/elem, struct, i31, ref_eq, ref_test, ref_cast,
ref_null, ref_is_null, ref_func, ref_as_non_null, br_on_cast/fail,
br_on_null/non_null, extern, type-equivalence, type-rec, type-subtyping.

**Fix approach**: Extend type parser to handle `(rec ...)`, `(sub ...)`,
`(struct ...)`, `(array ...)` declarations. Extend ref type parser for
`(ref $T)` and `(ref null $T)` syntax. Map to existing GC binary encoding.

### 4. NAMES — Function Index Resolution (460 failures, 1 file)

**Root cause**: The `names.0.wasm` module has 482 exported functions with
special characters (Unicode, whitespace, punctuation). The WAT parser
produces a module where function indices don't match the binary version,
causing FunctionIndexOutOfBounds at runtime.

**Affected syntax**: Not a syntax gap — the module loads but function
resolution produces incorrect indices.

**Fix approach**: Investigate index mapping between WAT parser output and
binary module. Likely a bug in function index assignment when many
functions share similar signatures.

### 5. SIMD — Lane Index and Const Syntax (288 failures, 2 files)

**Root cause**: simd_lane (268 failures) and simd_const (20 failures).
Likely related to `v128.const` with specific lane syntax or
`i8x16.shuffle` lane index parsing from wasm-tools output format.

**Affected files**: simd_lane, simd_const.

**Fix approach**: Compare wasm-tools WAT output for SIMD lane operations
against what the WAT parser accepts. Fix lane index parsing.

### 6. EH — Exception Handling (48 failures, 3 files)

**Root cause**: OutOfMemory when parsing try_table blocks (known W33).
The WAT parser's try_table implementation has a memory allocation issue.

**Affected files**: try_table (41), throw (2), throw_ref (5).

**Fix approach**: Debug OOM in try_table parsing. Likely unbounded
allocation in catch clause handling.

### 7. THREADS — Shared Memory (11 failures, 9 files)

**Root cause**: `(memory N M shared)` syntax not recognized.
The `shared` keyword on memory declarations is not parsed.

**Affected syntax**: `(memory (;0;) 1 1 shared)`

**Affected files**: threads-LB, threads-LB_atomic, threads-MP,
threads-MP_atomic, threads-SB, threads-SB_atomic, threads-simple,
threads-thread, threads-wait_notify.

**Fix approach**: In memory parsing, recognize `shared` keyword after
min/max pages. Set shared flag in memory definition.

## WAT Conversion Failures (708)

These are `wasm-tools print` failures on intentionally malformed modules
(assert_invalid, assert_malformed test data). Not fixable — expected behavior.

Categories:
- binary-leb128: 58 (malformed LEB128 encoding)
- binary: 105 (malformed binary structure)
- utf8-*: 528 (invalid UTF-8 encoding tests)
- custom: 8 (invalid custom sections)
- Other: 9 (align, binary-gc, global, etc.)

## Recommended Fix Order

1. **CORE block types** (2,754) — Highest impact, affects 65 core test files
2. **MEM64 syntax** (1,503) — Second highest, straightforward parser change
3. **THREADS shared** (11) — Trivial fix, small impact but easy win
4. **SIMD lane/const** (288) — Moderate complexity
5. **NAMES index** (460) — Investigation needed, may be a deeper bug
6. **GC types** (508) — Complex parser work (W30)
7. **EH OOM** (48) — Debug memory issue (W33)

Expected result after fixes 1-5: ~5,016 recovered → ~99.1% WAT pass rate.
After all fixes including GC+EH: ~5,572 recovered → ~100% (matching binary).
