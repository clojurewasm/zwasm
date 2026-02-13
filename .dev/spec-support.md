# zwasm Spec Support Matrix

Human-readable summary. **Single Source of Truth**: `.dev/status/compliance.yaml`

Per-opcode details live in code (`src/opcode.zig` enum).
Update compliance.yaml when implementing new opcode categories or WASI syscalls.

**Run tests**:
- Spec: `python3 test/spec/run_spec.py --summary` (60,873/60,906, 7 skips)
- E2E: `bash test/e2e/run_e2e.sh --summary` (356/356 = 100%, 70 files, Zig runner)

## Opcode Coverage Summary

| Category              | Implemented | Total | Notes                          |
|-----------------------|-------------|-------|--------------------------------|
| MVP (core)            | 172         | 172   | Full MVP coverage              |
| Sign extension        | 7           | 7     | i32/i64 extend ops             |
| Non-trapping f->i     | 8           | 8     | Saturating conversions         |
| Bulk memory           | 9           | 9     | Complete (table.copy/init)     |
| Reference types       | 5           | 5     | ref.null, ref.is_null, etc.    |
| Multi-value           | Yes         | -     | Multiple return values         |
| SIMD (v128)           | 236         | 236   | Full SIMD coverage             |
| Relaxed SIMD          | 20          | 20    | Non-deterministic SIMD ops     |
| Memory64 (table64)    | 0*          | 0*    | Extends existing ops with i64  |
| Wide arithmetic       | 4           | 4     | add128, sub128, mul_wide_s/u   |
| Tail calls            | 2           | 2     | return_call, return_call_indirect |
| Exception handling    | 3           | 3     | throw, throw_ref, try_table    |
| Function references   | 5           | 5     | call_ref, br_on_null, etc.     |
| GC                    | 31          | 31    | struct/array/cast/i31 ops      |
| **Total opcodes**     | **502+**    | **502+** | 100% (all proposals)        |

## WASI Preview 1

| Category        | Implemented | Total | Notes                           |
|-----------------|-------------|-------|---------------------------------|
| args_*          | 2           | 2     | args_get, args_sizes_get        |
| environ_*       | 2           | 2     | environ_get, environ_sizes_get  |
| clock_*         | 2           | 2     | time_get, res_get               |
| fd_*            | ~12         | 14    | readdir, renumber missing (W4)  |
| path_*          | 6           | 8     | readlink, symlink missing       |
| proc_*          | 2           | 2     | exit, raise                     |
| random_*        | 1           | 1     | random_get                      |
| sock_*          | 0           | 4     | Not implemented (W5)            |
| poll_oneoff     | 0           | 1     | Not implemented                 |
| **Total WASI**  | **~27**     | **35** | ~77%                           |

## Proposals Status

| Proposal              | Status       | Notes                              |
|-----------------------|--------------|------------------------------------|
| MVP                   | Complete     | All opcodes                        |
| Sign extension        | Complete     | Phase 1 proposal                   |
| Non-trapping f->i     | Complete     | Phase 1 proposal                   |
| Bulk memory           | Complete     | All 9 opcodes                      |
| Reference types       | Complete     | externref, funcref                 |
| Multi-value           | Complete     | Multiple returns                   |
| SIMD                  | Complete     | All 236 v128 opcodes               |
| Relaxed SIMD          | Complete     | 20 opcodes (0x100-0x113), 85/85 spec |
| Memory64              | Complete     | Wasm 3.0 — table64 + i64 addressing |
| Tail calls            | Complete     | return_call + return_call_indirect |
| Extended const        | Complete     | i32/i64 add/sub/mul in const exprs |
| Branch hinting        | Complete     | metadata.code.branch_hint section  |
| Exception handling    | Complete     | throw, try_table, catch clauses    |
| Wide arithmetic       | Complete     | 4 opcodes, 99/99 e2e (W14)        |
| Custom page sizes     | Complete     | page_size 1 or 65536, 18/18 e2e   |
| Multi-memory          | Complete     | Multiple memories, memarg bit 6    |
| Function references   | Complete     | 5 opcodes, 104/106 spec tests     |
| GC                    | Complete     | 31 opcodes (0xFB prefix), 16 unit tests |
| WAT parser            | Complete     | v128/SIMD, named locals/globals    |
| Component Model       | Not started  | Wasm 3.0 (W7)                     |
| WASI Preview 2        | Not started  | Wasm 3.0                          |

## E2E Test Status

70 wasmtime misc_testsuite files ported. 356/356 assertions pass (100%, Zig runner with shared Store).

| Category                  | Status                   | Checklist         |
|---------------------------|--------------------------|-------------------|
| wast2json NaN syntax      | 1 file skipped           | W16               |
| .wat files                | 2 files skipped          | W17 (partial)     |
