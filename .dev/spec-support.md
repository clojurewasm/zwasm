# zwasm Spec Support Matrix

Human-readable summary. Per-opcode details live in code (`src/opcode.zig` enum).

**Run tests**:
- Spec: `python3 test/spec/run_spec.py --build --summary` (62,263/62,263 = 100%, 0 skips)
- E2E: `python3 test/e2e/run_e2e.py --convert --summary` (796/796 = 100%, 0 leak)
- All gates: `bash scripts/gate-commit.sh`

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
| Threads (0xFE)        | 79          | 79    | atomic load/store/rmw/cmpxchg  |
| **Total opcodes**     | **581+**    | **581+** | 100% (all proposals)        |

## WASI Preview 1

| Category        | Implemented | Total | Notes                           |
|-----------------|-------------|-------|---------------------------------|
| args_*          | 2           | 2     | args_get, args_sizes_get        |
| environ_*       | 2           | 2     | environ_get, environ_sizes_get  |
| clock_*         | 2           | 2     | time_get, res_get               |
| fd_*            | 14          | 14    | Full (incl. renumber, readdir)  |
| path_*          | 8           | 8     | Full (incl. symlink, link)      |
| proc_*          | 2           | 2     | exit, raise                     |
| random_*        | 1           | 1     | random_get                      |
| sock_*          | 4           | 4     | NOSYS stubs (W5)                |
| poll_oneoff     | 1           | 1     | CLOCK sleep, FD pass-through    |
| **Total WASI**  | **46**      | **46** | 100% (all registered)          |

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
| Threads               | Complete     | 79 opcodes (0xFE prefix), 310/310 spec  |
| WAT parser            | Complete     | data/elem, 0xFC/0xFD/0xFE prefix, try_table, SIMD lanes, Wasm 3.0 opcodes (GC 0xFB deferred) |
| Component Model       | Complete     | WIT, binary, Canon ABI, linker    |
| WASI Preview 2        | Complete     | 14 interfaces via P1 adapter      |

## E2E Test Status

796/796 assertions pass (100%, 0 leak). Gate-hardened: 87 validation skips + 18 infra skips eliminated.

## Real-World Compatibility

50/50 programs pass on Mac + Ubuntu (18 C + 7 C++ + 9 Go + 12 Rust + 4 TinyGo).
Windows: 25/25 (C+C++ subset only; Go/Rust/TinyGo provisioning on Windows is W52).
