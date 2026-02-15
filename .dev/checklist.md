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
| ~~W16~~ | ~~wast2json NaN literal syntax~~ | ~~0~~ | ~~RESOLVED~~ | Migrated to wasm-tools. wabt removed from project. |
| ~~W21~~ | ~~wast2json GC WAT text format~~ | ~~0~~ | ~~RESOLVED~~ | wasm-tools 1.244.0 converts all 18 GC files. 472/546 pass (86.4%). |
| ~~W17~~ | ~~.wat file support (native WAT parser)~~ | ~~0~~ | ~~RESOLVED (Stage 12)~~ | Completed. WAT parser with v128/SIMD, named locals/globals/labels, build-time optional. issue12170.wat validates OK. issue11563.wat out of scope (multi-module + GC). |

## Future improvements

| ID   | Item                                | Trigger    | Notes                                    |
|------|-------------------------------------|------------|------------------------------------------|
| ~~W20~~ | ~~GC collector (mark-and-sweep)~~ | ~~Post Stage 18~~ | ~~RESOLVED. Stage 19 C1-C4. Mark-and-sweep with threshold trigger.~~ |

## Wasm proposals (assigned to stages)

| ID   | Item                          | Stage | E2E Blocked              | Notes                                    |
|------|-------------------------------|-------|--------------------------|------------------------------------------|
| ~~W18~~ | ~~Memory64 table operations~~ | ~~7~~ | ~~RESOLVED~~ | Completed in Stage 7. All 252 memory64 spec tests pass. |
| W13 | Exception handling: throw_ref | 28.6 | 1 spec failure | throw/try_table/catch done. throw_ref stub returns error.Trap — needs exnref value impl. |

## Spec failure tracking (103 remaining, added 28.2)

All remaining spec failures tracked here to prevent forgetting. Each maps to a memo.md task.

| ID   | Category                        | Fails | Task   | Root Cause                                                   |
|------|---------------------------------|-------|--------|--------------------------------------------------------------|
| W22  | Multi-module linking            | 36    | 28.2c  | Spec runner lacks cross-module state sharing (register/import)|
| W23  | GC subtyping                    | ~48   | 28.3   | Type hierarchy checks missing: ref_test, type-subtyping, br_on_cast, i31, array, elem |
| W24  | GC type canonicalization        | 5     | 28.4   | type-equivalence 3, type-rec 2: recursive type group equality |
| W25  | endianness64 (Ubuntu only)      | 15    | 28.2e  | x86 byte order for memory64 64-bit load/store ops            |
| W26  | externref representation        | 2     | 28.5   | externref(0) conflated with null (extern 1 + ref_is_null 1)  |
| W27  | throw_ref opcode                | 1     | 28.6   | = W13. Stub returns error.Trap, needs exnref value handling  |
| W28  | call batch state loss           | 1     | 28.7   | Spec runner: process state lost after invoke; needs_state fix regresses |
| W29  | threads spec                    | 4     | 29.2   | Need thread spawning mechanism (wait/notify partially working)|
| ~~W14~~ | ~~Wide arithmetic (i128)~~ | ~~9~~ | ~~RESOLVED~~ | Completed in Stage 9. 4 opcodes, 99/99 e2e tests. |
| ~~W15~~ | ~~Custom page sizes~~ | ~~10~~ | ~~RESOLVED~~ | Completed in Stage 10. page_size 1 or 65536. 18/18 e2e tests. |
