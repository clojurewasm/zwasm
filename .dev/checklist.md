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

Resolved: W9 (transitive import chains) fixed in 5F.2.

## Test infrastructure (from E2E 5E)

| ID   | Item                                        | Fails | Root Cause                           | Resolution Approach                      |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| W10  | Cross-process table side effects            | 1     | partial-init-table-segment.wast: failed instantiation should modify shared table, but each module runs in separate process. assert_uninstantiable detection fixed (5F.4), but side effect not visible. | Needs single-process multi-module protocol. Low priority — only 1 assertion affected. |
| W16  | wast2json NaN literal syntax                | 0     | simd/canonicalize-nan.wast uses NaN syntax wast2json 1.0.39 can't parse. No upgrade available. | Blocked on wabt release. File skipped in conversion. |
| W17  | .wat file support (native WAT parser)       | 0     | issue11563.wat (GC+exceptions) and issue12170.wat (SIMD smoke test) currently skipped. | Implement native WAT parser as future stage (see roadmap.md "WAT Parser & Build-time Feature Flags"). Build-time optional (`-Dwat=false`). Resolves .wat test files and adds `zwasm run file.wat` + `WasmModule.loadFromWat()` API. |

## Wasm proposals (assigned to stages)

| ID   | Item                          | Stage | E2E Blocked              | Notes                                    |
|------|-------------------------------|-------|--------------------------|------------------------------------------|
| ~~W18~~ | ~~Memory64 table operations~~ | ~~7~~ | ~~RESOLVED~~ | Completed in Stage 7. All 252 memory64 spec tests pass. |
| ~~W13~~ | ~~Exception handling~~ | ~~8~~ | ~~RESOLVED~~ | throw, try_table, catch clauses done. throw_ref stub. 38/38 spec. |
| ~~W14~~ | ~~Wide arithmetic (i128)~~ | ~~9~~ | ~~RESOLVED~~ | Completed in Stage 9. 4 opcodes, 99/99 e2e tests. |
| W15  | Custom page sizes             | 10    | memory-combos.wast       | Non-64KB page sizes in memory type       |
