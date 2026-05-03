# test/wasmtime_misc/wast/basic/

Per ADR-0012 §3 directory layout. Holds basic-op wast-derived
fixtures vendored from `bytecodealliance/wasmtime/tests/misc_testsuite/`
(BATCH1 of v1's `convert.py` classification).

These 12 .wasm files migrated from the dissolved
`test/v1_carry_over/{add,div-rem,empty,f64-copysign}/` directories
during ADR-0012 §6 work item 6.B. The runner driving them is
`test/spec/wast_runner.zig` (parse + validate only at this gate);
runtime-asserting coverage arrives when `test-wasmtime-misc-basic`
gets re-driven by `test/runners/wast_runtime_runner.zig` in §9.6 /
6.D after BATCH2-3 have been vendored.

Build step: `zig build test-wasmtime-misc-basic` (was
`test-v1-carry-over` before 6.B; renamed to align with origin-
based directory layout).
