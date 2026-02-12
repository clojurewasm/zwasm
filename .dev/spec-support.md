# zwasm Spec Support Matrix

Human-readable summary. **Single Source of Truth**: `.dev/status/compliance.yaml`

Per-opcode details live in code (`src/opcode.zig` enum).
Update compliance.yaml when implementing new opcode categories or WASI syscalls.

**Run tests**:
- Spec: `python3 test/spec/run_spec.py --summary` (30,715/30,715 = 100%)
- E2E: `bash test/e2e/run_e2e.sh --summary` (356/356 = 100%, 70 files, Zig runner)

## Opcode Coverage Summary

| Category              | Implemented | Total | Notes                         |
|-----------------------|-------------|-------|-------------------------------|
| MVP (core)            | 172         | 172   | Full MVP coverage             |
| Sign extension        | 7           | 7     | i32/i64 extend ops            |
| Non-trapping f->i     | 8           | 8     | saturating conversions        |
| Bulk memory           | 7           | 9     | table.copy/init stubbed (W1,W2)|
| Reference types       | 5           | 5     | ref.null, ref.is_null, etc.   |
| Multi-value           | Yes         | -     | Multiple return values         |
| SIMD (v128)           | 236         | 236   | Full SIMD coverage            |
| Memory64 (table64)    | 0*          | 0*      | Extends existing ops with i64|
| Wide arithmetic       | 4           | 4     | add128, sub128, mul_wide_s/u  |
| **Total opcodes**     | **439**     | **441** | 99.5% (2 stubs)            |

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
| Bulk memory           | Partial      | table ops stubbed (W1, W2)         |
| Reference types       | Complete     | externref, funcref                  |
| Multi-value           | Complete     | Multiple returns                   |
| SIMD                  | Complete     | All 236 v128 opcodes               |
| Memory64              | Complete     | Wasm 3.0 — table64 + i64 addressing |
| Tail calls            | Stub         | return_call/return_call_indirect trap |
| Exception handling    | Complete     | throw, try_table, catch clauses    |
| Wide arithmetic       | Complete     | 4 opcodes, 99/99 e2e (W14)         |
| Custom page sizes     | Complete     | page_size 1 or 65536, 18/18 e2e (W15) |
| WAT parser            | Complete     | v128/SIMD, named locals/globals, labels |
| GC                    | Not started  | Wasm 3.0                           |
| Component Model       | Not started  | Wasm 3.0 (W7)                      |
| WASI Preview 2        | Not started  | Wasm 3.0                           |

## E2E Test Status

70 wasmtime misc_testsuite files ported. 356/356 assertions pass (100%, Zig runner with shared Store).
Previously failing partial-init-table-segment now passes (bounds pre-check fix + shared Store).
Previously failing no-panic-on-invalid now passes (validateBodyEnd trailing bytes detection).

| Category                  | Status                   | Checklist         |
|---------------------------|--------------------------|-------------------|
| wast2json NaN syntax      | 1 file skipped           | W16               |
| .wat files                | 2 files skipped          | W17 (partial)     |
| memory-combos.wast        | 1 file skipped           | multi-memory      |

Notes: issue12170.wat validates via `zwasm validate` (no assertions to run).
issue11563.wat: multi-module format + GC proposal — out of scope.
Resolution plan: Stage 5F in roadmap.md. Full details in checklist.md.
