# zwasm Spec Support Matrix

Human-readable summary. **Single Source of Truth**: `.dev/status/compliance.yaml`

Per-opcode details live in code (`src/opcode.zig` enum).
Update compliance.yaml when implementing new opcode categories or WASI syscalls.

**Run tests**:
- Spec: `python3 test/spec/run_spec.py --summary` (30,703/30,703 = 100%)
- E2E: `bash test/e2e/run_e2e.sh --summary` (180/181 = 99.4%)

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
| **Total opcodes**     | **435**     | **437** | 99.5% (2 stubs)            |

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
| Tail calls            | Not started  | Wasm 3.0                           |
| Exception handling    | Not started  | Wasm 3.0 (W13)                     |
| Wide arithmetic       | Not started  | Wasm 3.0 (W14)                     |
| Custom page sizes     | Not started  | Wasm 3.0 (W15)                     |
| GC                    | Not started  | Wasm 3.0                           |
| Component Model       | Not started  | Wasm 3.0 (W7)                      |
| WASI Preview 2        | Not started  | Wasm 3.0                           |

## E2E Test Status

68 wasmtime misc_testsuite files ported. 10 remaining failures, 6 skipped files.

| Category                  | Status                   | Checklist         |
|---------------------------|--------------------------|-------------------|
| Cross-module type canon.  | 5 failures               | W8                |
| Cross-module table remap  | 4 failures               | W9                |
| assert_uninstantiable     | 1 failure                | W10               |
| wast2json NaN syntax      | 1 file skipped           | W16               |
| .wat file support         | 2 files skipped          | W17               |
| Exception handling        | 1 file skipped           | W13               |
| Wide arithmetic           | 1 file skipped           | W14               |
| Custom page sizes         | 1 file skipped           | W15               |

Resolution plan: Stage 5F in roadmap.md. Full details in checklist.md.
