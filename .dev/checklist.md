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
| ~~W2~~ | ~~table.init edge cases~~ | ~~CW F137~~ | ~~RESOLVED (cdb0c10). spec 1,548/1,548 (100%)~~ |
| ~~W4~~ | ~~WASI fd_readdir implementation~~ | ~~CW gap~~ | ~~RESOLVED. Stage 19 D2~~ |
| ~~W5~~ | ~~WASI sock_* family~~ | ~~CW gap~~ | ~~RESOLVED. Stage 19 D6 (NOSYS stubs)~~ |
| W7   | Component Model basics              | New        | Stage 3                               |

## Cross-module linking (from E2E 5E)

Resolved: W9 (transitive import chains) fixed in 5F.2.

## Test infrastructure (from E2E 5E)

| ID   | Item                                        | Fails | Root Cause                           | Resolution Approach                      |
|------|---------------------------------------------|-------|--------------------------------------|------------------------------------------|
| ~~W10~~ | ~~Cross-process table side effects~~ | ~~0~~ | ~~RESOLVED~~ | Fixed by Zig E2E runner with shared Store. partial-init-table-segment 3/3 pass. |
| W16  | wast2json NaN literal syntax                | 0     | simd/canonicalize-nan.wast uses NaN syntax wast2json 1.0.39 can't parse. No upgrade available. | Blocked on wabt release. File skipped in conversion. |
| ~~W21~~ | ~~wast2json GC WAT text format~~ | ~~0~~ | ~~RESOLVED~~ | wasm-tools 1.244.0 converts all 18 GC files. 472/546 pass (86.4%). |
| ~~W17~~ | ~~.wat file support (native WAT parser)~~ | ~~0~~ | ~~RESOLVED (Stage 12)~~ | Completed. WAT parser with v128/SIMD, named locals/globals/labels, build-time optional. issue12170.wat validates OK. issue11563.wat out of scope (multi-module + GC). |

## Future improvements

| ID   | Item                                | Trigger    | Notes                                    |
|------|-------------------------------------|------------|------------------------------------------|
| W20  | GC collector (mark-and-sweep)             | Post Stage 18 | Stage 19 Group C. Simple mark-and-sweep without compaction first. Generational/Immix upgrade later. |

## Wasm proposals (assigned to stages)

| ID   | Item                          | Stage | E2E Blocked              | Notes                                    |
|------|-------------------------------|-------|--------------------------|------------------------------------------|
| ~~W18~~ | ~~Memory64 table operations~~ | ~~7~~ | ~~RESOLVED~~ | Completed in Stage 7. All 252 memory64 spec tests pass. |
| ~~W13~~ | ~~Exception handling~~ | ~~8~~ | ~~RESOLVED~~ | throw, try_table, catch clauses done. throw_ref stub. 38/38 spec. |
| ~~W14~~ | ~~Wide arithmetic (i128)~~ | ~~9~~ | ~~RESOLVED~~ | Completed in Stage 9. 4 opcodes, 99/99 e2e tests. |
| ~~W15~~ | ~~Custom page sizes~~ | ~~10~~ | ~~RESOLVED~~ | Completed in Stage 10. page_size 1 or 65536. 18/18 e2e tests. |
