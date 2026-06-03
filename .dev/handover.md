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
- **Cycles-remaining**: ~3 (cycle-1 memory+globals; cycle-2 tables/elem + WASI imports; cycle-2+ GC +
  cross-module imports)
- **Continuity-memo**: §12.3b serialises module STATE into `.cwasm` v0.3 + reconstructs a real runtime from the
  artefact alone (AOT analogue of `setup.setupRuntimeLinked`, src/engine/setup.zig:229 — today it builds from
  `CompiledWasm`+`.wasm`). Survey (this cycle): JitRuntime state built at setup.zig — memory (`vm_base`/`mem_limit`
  @975-988: alloc min_pages×64KB, memcpy active data segments), globals (`globals_base` @985, `globals_buf` @477,
  per-global const-expr eval @575-580), tables/elem (@620-951), host_dispatch (@284, WASI). **Cycle-1 = memory +
  globals only** (no tables/imports/GC): v0.3 header adds `memory_{min,max}_pages` + `memory_init_{offset,size}`
  (data bytes) + `globals_{offset,size}` (n_globals + pre-evaluated u64 values, serialise the FINAL values not
  init-exprs — simple i32/i64/f/v128.const + ref.null/i31; NO global.get-import/struct.new in cycle-1).
  Reconstruction in `aot/run.zig`: alloc+init memory, build globals_buf from serialised values, set
  `vm_base`/`globals_base` (drop the zero-pad for those). Format mirrors the exports-section pattern (ADR-0138:
  header offset/size pair + `[count][entries]`). Producer side: `CompiledWasm` already carries globals
  (`globals_offsets`/`globals_valtypes`) + the module; thread memory+global-init into `serialise.Input`.
- **Exit-condition**: a memory+globals-using `()→i32` fixture (e.g. reads a global / writes+reads memory)
  produced to `.cwasm` then `zwasm run` → correct result (currently TRAPS). §12.3b cycle-1 `[x]` on that.

## Next task (autonomous)

§12.3b cycle-1 — stateful `.cwasm` (memory + globals). Smallest red test: a `()→i32` fixture that reads a
declared global (or writes+reads linear memory) → produce `.cwasm` → `runCwasm` (currently TRAPS, the red). Green
= v0.3 format (memory_{min,max}_pages + memory_init + globals sections per the bundle continuity-memo) + producer
serialise (thread memory+global-init from `CompiledWasm`/Module into `serialise.Input`) + `aot/run.zig`
reconstruction (alloc+init memory, build globals_buf, set `vm_base`/`globals_base`). Cycle-1 scope = NO
tables/elem/imports/GC (simple const-expr global inits only). Bundle continuity-memo has the setup.zig anchors.

## Deferred / open debt (none a Phase-12 blocker)

- **D-249** Windows bench timing (hyperfine on windowsmini) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn = planning only (ADR-0139 re-sequence + §12.3b/§12.5 surveys + bundle setup); no `src/` behavior
change beyond D-250→§12.3b comment syncs, so NO ubuntu kick owed. Prior ubuntu verified `8235e6a9` OK; last code
HEAD unchanged. Next resume: no ubuntu verification pending; start §12.3b cycle-1. Phase-12 exec tests skip Win64
via `skip.phaseEnd` (§12.3b/ADR-0139); windowsmini = phase-boundary.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria ~line 1432; §12.3/12.4/12.5 task rows); Phase Status widget.
- ADR-0139 (Phase-12 re-sequence: §12.3b stateful `.cwasm` before §12.4; §12.5 Phase-15-coupled); ADR-0138
  (v0.2 exports); ADR-0040/0039 (AOT substrate); ADR-0117 (GC stack-map §12.5); ADR-0067 (3-host); ADR-0136.
- `setup.setupRuntimeLinked` (setup.zig:229) = the reconstruction template. Survey: `p12-12.1-aot-loader-survey.md`.
