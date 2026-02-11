# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Known gaps from CW extraction

| ID   | Item                                | Source     | Trigger                               |
|------|-------------------------------------|------------|---------------------------------------|
| W1   | table.copy cross-table support      | CW F136    | Currently stub in CW                  |
| W2   | table.init implementation           | CW F137    | Currently stub in CW                  |
| W4   | WASI fd_readdir implementation      | CW gap     | WASI P1 completion (Stage 2)          |
| W5   | WASI sock_* family                  | CW gap     | WASI P1 completion (Stage 2)          |
| W7   | Component Model basics              | New        | Stage 3                               |

## Cross-module linking (from E2E 5E)

| ID   | Item                                        | Fails | Root Cause                           | Resolution Approach                      |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W8   | Cross-module type signature matching        | 5     | call_indirect across modules uses module-local type indices; imported function's type index doesn't match the calling module's type table | Implement type canonicalization: when importing a function, remap its type index to the equivalent entry in the importing module's type table. Compare type signatures structurally (param types + return types), not by index. See wasmtime `wasmtime-environ/src/module.rs` for reference. |
| W9   | Cross-module table func ref remap           | 4     | When copying a table between modules, function references are remapped but some edge cases fail: (a) null refs in non-zero positions, (b) functions with mismatched type indices, (c) table.copy where source and dest are different imported tables | Fix edge cases in `types.zig registerImports()` table sharing logic. Need to handle: null-but-non-zero entries, type index remapping for copied functions, and multi-hop import chains (A imports from B which imports from C). |

## Test infrastructure (from E2E 5E)

| ID   | Item                                        | Fails | Root Cause                           | Resolution Approach                      |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W10  | assert_uninstantiable side effect tracking  | 1     | partial-init-table-segment.wast: first instantiation succeeds but has side effects on a shared table. Second module's assert_uninstantiable should see these side effects but our test runner creates independent batch processes per module. | Extend run_spec.py BatchRunner to support multi-module state within a single test file. When a new module command appears after assert_uninstantiable, preserve the table/memory state from the previous instantiation. Alternative: handle assert_uninstantiable as actual instantiation attempt (not just validation). |
| W16  | wast2json NaN literal syntax                | 1     | simd/canonicalize-nan.wast uses NaN literal syntax (`nan:0x200000`) that wast2json 1.0.39 cannot parse | Upgrade to wast2json >= 1.0.40 (if available) or write a custom NaN literal pre-processor that converts the syntax before wast2json. Check wabt releases for fix. |
| W17  | .wat file support in test runner            | 2     | issue11563.wat and issue12170.wat are raw WAT files, not WAST. run_spec.py only handles wast2json output (JSON + .wasm). | Add .wat support to run_spec.py: detect .wat files, compile with wat2wasm, run the resulting .wasm directly (no assertions — just verify it loads and runs without crash). |

## Wasm proposals (future stages)

| ID   | Item                                        | Scope | E2E Files Blocked                    | Notes                                    |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W13  | Exception handling (exnref)                 | Large | issue11561.wast                      | Wasm 3.0 proposal. Requires new opcodes: try, catch, throw, rethrow. Reference: wasm-spec exception-handling proposal. |
| W14  | Wide arithmetic (i64.add128 etc.)           | Medium| wide-arithmetic.wast                 | Newer proposal. 3 new opcodes: i64.add128, i64.sub128, i64.mul_wide_s/u. Straightforward to implement once the proposal stabilizes. |
| W15  | Custom page sizes                           | Small | memory-combos.wast                   | Allows non-64KB page sizes. Requires changes to memory allocation and grow logic. |
