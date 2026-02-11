# zwasm Spec Support Matrix

Feature coverage tracking. Per-opcode details live in code (`src/opcode.zig` enum).
Update this file when implementing new opcode categories or WASI syscalls.

**Machine-readable compliance data**: `.dev/status/compliance.yaml`
**E2E tests**: `bash test/e2e/run_e2e.sh --summary` (68 wasmtime misc_testsuite files)

## Opcode Coverage Summary

| Category              | Implemented | Total | Notes                         |
|-----------------------|-------------|-------|-------------------------------|
| MVP (core)            | 172         | 172   | Full MVP coverage             |
| Sign extension        | 7           | 7     | i32/i64 extend ops            |
| Non-trapping f→i      | 8           | 8     | saturating conversions        |
| Bulk memory           | 7           | 9     | table.copy/init stubbed (W1,W2)|
| Reference types       | 5           | 5     | ref.null, ref.is_null, etc.   |
| Multi-value           | Yes         | —     | Multiple return values         |
| SIMD (v128)           | 236         | 236   | Full SIMD coverage            |
| **Total opcodes**     | **435**     | **437** | 99.5% (2 stubs)            |

## WASI Preview 1

| Category        | Implemented | Total | Notes                           |
|-----------------|-------------|-------|---------------------------------|
| args_*          | 2           | 2     | args_get, args_sizes_get        |
| environ_*       | 2           | 2     | environ_get, environ_sizes_get  |
| clock_*         | 2           | 2     | time_get, res_get               |
| fd_*            | ~12         | 14    | readdir, renumber missing       |
| path_*          | 6           | 8     | Most implemented                |
| proc_*          | 2           | 2     | exit, raise                     |
| random_*        | 1           | 1     | random_get                      |
| sock_*          | 0           | 4     | Not implemented (W5)            |
| **Total WASI**  | **~27**     | **35** | ~77%                           |

## Proposals Status

| Proposal              | Status       | Notes                              |
|-----------------------|--------------|------------------------------------|
| MVP                   | Complete     | All opcodes                        |
| Sign extension        | Complete     | Phase 1 proposal                   |
| Non-trapping f→i      | Complete     | Phase 1 proposal                   |
| Bulk memory           | Partial      | table ops stubbed (W1, W2)         |
| Reference types       | Complete     | externref, funcref                  |
| Multi-value           | Complete     | Multiple returns                   |
| SIMD                  | Complete     | All 236 v128 opcodes               |
| Tail calls            | Not started  | Stage 2+                           |
| Exception handling    | Not started  | Stage 2+                           |
| GC                    | Not started  | Stage 3                            |
| Component Model       | Not started  | Stage 3 (W7)                       |
| WASI Preview 2        | Not started  | Stage 3                            |

## Key Optimizations (carried from CW)

- Predecoded IR: fixed-width instruction format for cache-friendly dispatch
- 11 superinstructions: fused compare-and-branch, arithmetic-on-locals
- VM reuse: cached Vm per WasmModule, reset() per invocation
- Sidetable: lazy branch target resolution in WasmFunction
