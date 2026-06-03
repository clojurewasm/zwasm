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
- **Cycles-remaining**: ~3 (cycle-1a globals DONE; cycle-1b memory NEXT; cycle-2 tables/elem + WASI imports;
  cycle-2+ GC + cross-module imports)
- **Continuity-memo**: §12.3b serialises module STATE into `.cwasm` v0.3 + reconstructs a real runtime from the
  artefact alone (AOT analogue of `setup.setupRuntimeLinked`, setup.zig:229). **CYCLE-1a GLOBALS DONE
  (`797a7ef0`, CLI-smoke exit 42)**: `.cwasm` v0.3 (header 68→76 B, `globals_offset`/`globals_size`; section =
  `[n_globals:u32][n×16B Value.bits128]`). `produceFromCompiledWasm` now takes `wasm_bytes`, re-parses + evals
  defined-global init-exprs via `instantiate.evalConstExprValue` (`collectGlobalInits`; cycle-1 simple consts —
  ref.func/global.get/struct.new → `UnsupportedGlobalInit`). `load.parseGlobals` → `LoadedModule.globals:[]u128`;
  `aot/run.runEntry` sets `globals_base = @ptrCast(globals.ptr)` (u128≡Value, 16B, no copy). **CYCLE-1b MEMORY
  (NEXT)**: v0.3→add `memory_{min,max}_pages` + `memory_init_{offset,size}` (data segments `[n_seg][mem_off:u32,
  len:u32, bytes]`, active only, offset-expr evaluated at produce). Reconstruct in `runEntry`: alloc
  min_pages×64KB, memcpy segments, set `vm_base`/`mem_limit` — **must FREE the memory buffer after the call**
  (unlike globals which alias `mod.globals`). setup.zig anchors: memory alloc @384-419 (decodeMemory/decodeData),
  `vm_base`/`mem_limit` @975-988. Producer: `module.find(.memory)`/`.data` + offset-expr via evalConstExprValue.
- **Exit-condition**: cycle-1b — a memory store+load `()→i32` fixture produced to `.cwasm` then `zwasm run` →
  correct result (currently TRAPS, mem_limit 0). Bundle continues to cycle-2 (tables/elem/WASI) after.

## Next task (autonomous)

§12.3b cycle-1b — memory. Smallest red test: a `(memory 1)(func (export "m")(result i32) i32.const 0; i32.const
99; i32.store; i32.const 0; i32.load)` fixture → produce `.cwasm` → `aot_run.runEntry` (currently TRAPS: the
minimal runtime's mem_limit=0 → store bounds-traps). Green = v0.3 memory header fields + data-segment section +
`runEntry` allocs min_pages×64KB, memcpys data, sets `vm_base`/`mem_limit`, **frees after the call**. Mirror the
globals chunk (`797a7ef0`). Bundle continuity-memo has the setup.zig anchors + the FREE-lifetime caveat.

## Deferred / open debt (none a Phase-12 blocker)

- **D-249** Windows bench timing (hyperfine on windowsmini) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn landed §12.3b cycle-1a globals (`797a7ef0`): `.cwasm` v0.3 + globals reconstruction, Mac test+lint+zone
green, CLI smoke (`zwasm compile glob.wasm; zwasm run --invoke g` → exit 42). An ubuntu `test` is kicked against
this turn's final HEAD → next resume `tail /tmp/ubuntu.log` for OK (verifies x86_64-SysV globals_base
reconstruction). Prior ubuntu verified `8235e6a9` OK. Phase-12 exec tests skip Win64 via `skip.phaseEnd`;
windowsmini = phase-boundary.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria ~line 1432; §12.3/12.4/12.5 task rows); Phase Status widget.
- ADR-0139 (Phase-12 re-sequence: §12.3b stateful `.cwasm` before §12.4; §12.5 Phase-15-coupled); ADR-0138
  (v0.2 exports); ADR-0040/0039 (AOT substrate); ADR-0117 (GC stack-map §12.5); ADR-0067 (3-host); ADR-0136.
- `setup.setupRuntimeLinked` (setup.zig:229) = the reconstruction template. Survey: `p12-12.1-aot-loader-survey.md`.
