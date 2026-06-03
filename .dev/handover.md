# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **12 IN-PROGRESS — AOT compilation mode**. §12.0/§12.1/§12.2/§12.3 `[x]`. **Re-sequenced per
  ADR-0139**: both remaining feature rows are blocked on larger work — §12.4 (cold-start bench) on §12.3b
  (real v1-class fixtures use memory → trap on the stateless AOT path, empirically verified gimli/fib2), §12.5
  (stack-map) on Phase-15 (`zir.GcRootMap` is an empty placeholder, no shape to serialise). **The one
  substantive do-now row = §12.3b (stateful `.cwasm`)** — promoted from D-250 to an explicit row. Phase 11 DONE.
- **§12.1/§12.2/§12.3 done** (see ROADMAP + ADR-0138/0139): `.cwasm` v0.2 (exports section) loader+runner runs
  STATELESS void/i32 entries end-to-end (`zwasm compile`→`run`, smoke exit 42); JIT↔AOT differential; toolchain
  cross-compile gate (`check_aot_cross_compile.sh`). The standalone runner (`aot/run.zig`) builds a minimal
  zero-state `JitRuntime` → real (memory/globals-using) modules trap, which §12.3b fixes.

## Active bundle

- **Bundle-ID**: 12.3b-stateful-cwasm
- **Cycles-remaining**: ~1-2 (cycle-1 memory+globals + cycle-2a tables/elem DONE; cycle-2b WASI imports NEXT;
  cycle-2+ GC + cross-module imports)
- **Continuity-memo**: §12.3b serialises module STATE into `.cwasm` v0.3 + reconstructs a real runtime from the
  artefact alone (AOT analogue of `setup.setupRuntimeLinked`, setup.zig:229). **CYCLE-1 DONE — globals
  (`797a7ef0`) + memory (`58e97a09`)**, both CLI-smoke-verified (`zwasm run` → 42). `.cwasm` v0.3 header now 92 B:
  globals (`globals_offset/size`, section `[n:u32][n×16B Value.bits128]`) + memory (`flags & flag_has_memory`,
  `memory_{min,max}_pages`, `memory_init_{offset,size}` = active data segs `[n][mem_off:u32,len:u32,bytes]`).
  `produceFromCompiledWasm(…, wasm_bytes)` re-parses + evals: `collectGlobalInits` (evalConstExprValue) +
  `collectMemory` (decodeMemory/decodeData + `runner_validate.evalConstOffsetU64`). `load.{parseGlobals,
  parseMemData}` → `LoadedModule.{globals:[]u128, has_memory, mem_min_pages, mem_data}`. `aot/run.runEntry`:
  `globals_base=@ptrCast(globals.ptr)` (alias, no copy) + allocs min_pages×64KB, memcpys data, sets
  `vm_base`/`mem_limit`, **FREEs after the call**. Subset guards loud (`UnsupportedGlobalInit`/`MemoryState`).
  **PITFALL hit + fixed**: `i32.const` is SIGNED LEB128 — `0x63` (99) decodes as -29 (bit-6 set); use values <64
  or multi-byte SLEB in hand-rolled fixtures. **EMPIRICAL (this turn)**: shootout fixtures (gimli/fib2/sieve)
  still TRAP after cycle-1 — gimli imports `proc_exit` + has a table+elem, so v1-class fixtures need cycle-2
  (imports AND tables), not just memory+globals. **CYCLE-2a TABLES/ELEM DONE (`9b416428`, CLI-smoke exit 7)**: v0.3
  header +`table0_size`+`elem_{offset,size}` (flag bit `flag_has_table`), `CwasmFuncMeta` +`canon_typeidx`
  (12→16B), elem_data section `[n_seg][table_offset:u32][n_funcs:u32][funcidx...]`. produce `collectTables`
  (decodeTables/decodeElement + `canonical_type.canonicalTypeidx` per defined func). `load.buildTable` computes
  `funcptr_base[slot]=@intFromPtr(block.ptr+func_offsets[F-n_imports])` + `typeidx_base[slot]=canon` (maxInt
  sentinel for empty); runEntry aliases them (table-0 fast path = scalars). MVP non-subtyping single-table-0.
  **CYCLE-2b WASI IMPORTS (NEXT)**: serialise import metadata (module+name+kind) + reconstruct
  `host_dispatch_base` via the WASI registry. setup.zig `populateDispatch`@284; `wasi/jit_dispatch.zig` has the
  d-2 handlers (fd_write/clock/random/args/environ). Then a real tinygo guest (`bench/runners/wasm/tinygo/*`)
  runs AOT → bundle closes + unblocks §12.4. NOTE: shootout `_start` calls `proc_exit` → that import must wire.
- **Exit-condition**: cycle-2b — a WASI-importing `.cwasm` (fd_write / proc_exit) runs via `zwasm run`. Bundle
  closes when a real v1-class fixture (tinygo guest) runs AOT → unblocks §12.4 bench.

## Next task (autonomous)

§12.3b cycle-2b — WASI imports. Smallest red test: the `proc_exit_42` fixture (cli/run.zig:280) — a func import
`wasi_snapshot_preview1.proc_exit` + `_start`/`main` calling it → produce `.cwasm` → `runCwasm` (currently the
import call traps: host_dispatch_base is the zero-pad / default trap). Green = serialise import metadata
(module+name+kind, n_imports already in header) + a v0.3 imports section + `aot/run.zig` reconstructs
`host_dispatch_base` from the WASI registry (`wasi/jit_dispatch.zig` d-2 handlers: fd_write/clock/random/args/
environ + proc_exit). Survey the host-dispatch wiring (`setup.populateDispatch`@284) first. Then a tinygo guest
runs AOT → bundle closes + §12.4 unblocks.

## Deferred / open debt (none a Phase-12 blocker)

- **D-249** Windows bench timing (hyperfine on windowsmini) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn landed §12.3b cycle-2a tables/elem (`9b416428`): v0.3 table0+elem+canon_typeidx, Mac test+lint+zone
green, CLI smoke (`zwasm run --invoke g ci.cwasm` → exit 7, call_indirect). An ubuntu `test` is kicked against
this turn's final HEAD → next resume `tail /tmp/ubuntu.log` for OK (verifies x86_64-SysV funcptr/typeidx_base +
call_indirect). Prior ubuntu verified `f74a258c` OK (memory). Phase-12 exec tests skip Win64 via `skip.phaseEnd`;
windowsmini = phase-boundary.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria ~line 1432; §12.3/12.4/12.5 task rows); Phase Status widget.
- ADR-0139 (Phase-12 re-sequence: §12.3b stateful `.cwasm` before §12.4; §12.5 Phase-15-coupled); ADR-0138
  (v0.2 exports); ADR-0040/0039 (AOT substrate); ADR-0117 (GC stack-map §12.5); ADR-0067 (3-host); ADR-0136.
- `setup.setupRuntimeLinked` (setup.zig:229) = the reconstruction template. Survey: `p12-12.1-aot-loader-survey.md`.
