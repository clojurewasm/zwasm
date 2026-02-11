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
| W2   | table.init implementation           | CW F137    | Currently stub in CW                  |
| W4   | WASI fd_readdir implementation      | CW gap     | WASI P1 completion (Stage 2)          |
| W5   | WASI sock_* family                  | CW gap     | WASI P1 completion (Stage 2)          |
| W7   | Component Model basics              | New        | Stage 3                               |

## Cross-module linking (from E2E 5E)

| ID   | Item                                        | Fails | Root Cause                           | Resolution Approach                      |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W9   | Transitive import chains in --link          | 2     | Module $o imports table from $n which itself imports from $m. --link loads each linked module independently without resolving its own imports, so $n fails to load when used as a link target. | Support chained imports: when loading a linked module, also pass other linked modules as its import sources. Low priority — only affects 3+ module chains. |

## Test infrastructure (from E2E 5E)

| ID   | Item                                        | Fails | Root Cause                           | Resolution Approach                      |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W10  | Cross-process table side effects            | 1     | partial-init-table-segment.wast: failed instantiation should modify shared table, but each module runs in separate process. assert_uninstantiable detection fixed (5F.4), but side effect not visible. | Needs single-process multi-module protocol. Low priority — only 1 assertion affected. |
| W16  | wast2json NaN literal syntax                | 0     | simd/canonicalize-nan.wast uses NaN syntax wast2json 1.0.39 can't parse. No upgrade available. | Blocked on wabt release. File skipped in conversion. |
| W17  | .wat file support (native WAT parser)       | 0     | issue11563.wat (GC+exceptions) and issue12170.wat (SIMD smoke test) currently skipped. | Implement native WAT parser as future stage (see roadmap.md "WAT Parser & Build-time Feature Flags"). Build-time optional (`-Dwat=false`). Resolves .wat test files and adds `zwasm run file.wat` + `WasmModule.loadFromWat()` API. |

## Wasm proposals (future stages)

| ID   | Item                                        | Scope | E2E Files Blocked                    | Notes                                    |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W13  | Exception handling (exnref)                 | Large | issue11561.wast                      | Wasm 3.0 proposal. Requires new opcodes: try, catch, throw, rethrow. Reference: wasm-spec exception-handling proposal. |
| W14  | Wide arithmetic (i64.add128 etc.)           | Medium| wide-arithmetic.wast                 | Newer proposal. 3 new opcodes: i64.add128, i64.sub128, i64.mul_wide_s/u. Straightforward to implement once the proposal stabilizes. |
| W15  | Custom page sizes                           | Small | memory-combos.wast                   | Allows non-64KB page sizes. Requires changes to memory allocation and grow logic. |
