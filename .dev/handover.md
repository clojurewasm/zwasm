# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **12 IN-PROGRESS — AOT compilation mode**. §12.0 / §12.1 / §12.2 / §12.3 all `[x]`; next `[ ]` =
  §12.4 (cold-start bench-delta ≥30%). Phase 11 DONE (`bbc4900b`, 3-host `test-all` reconcile GREEN; WASI 0.1 +
  bench Mac+Linux per ADR-0137 + SIMD gap profile; §11.4 → Phase 15 per ADR-0135).
- **§12.3 cross-compile `[x]`** (`617a4ae4`): `scripts/check_aot_cross_compile.sh` (x86_64-linux + aarch64-linux
  + x86_64-windows-gnu, exe compile-only, all green) wired into `gate_merge`. Cross-ARCH *emission* stays
  deferred (ADR-0039 Alt D — emit backend comptime host-pinned); the cross-compiled toolchain produces+runs a
  native `.cwasm` on its host (per-host `runCwasm` round-trip: Mac arm64 + ubuntu x86_64; windowsmini exec @ 12.P).
- **§12.1 `.cwasm` loader + runner — CLOSED end-to-end** (smoke-verified: `zwasm compile f.wasm -o f.cwasm` then
  `zwasm run --invoke f f.cwasm` → exit 42). Pipeline: loader CORE (`ca69fc68`,`50b4bd1a`) → entry-point design
  **ADR-0138** (`.cwasm` v0.2 exports section; header 60→68 B w/ `exports_offset`+`exports_size`; section =
  `[n_exports][name_len,name,func_idx]…`, func-kind only) → v0.2 format-layer (`926bed9f`) → producer exports
  wiring (`e090562d`: `CompiledWasm.exports` arena-owned via `collectFuncExports`, forwarded by
  `produceFromCompiledWasm`) → standalone runner `aot/run.zig` (`c7246e3c`: minimal stateless `JitRuntime` —
  zero counts, base ptrs alias a zero pad, never dereferenced; `runEntry` dispatches void/i32 by the loader's
  parsed result kind) → `cli/run.zig` `runCwasm` + main.zig `CWAS`-magic branch (`cf983dff`).
- **§12.2 differential `[x]`** (`bd138990`,`d0c1281e`): JIT vs AOT equal across i32/i64 const + internal-call
  reloc through the real `compileWasm`→produce→`load` pipeline.
- **Scope limit (D-250)**: the standalone runner handles the STATELESS subset (void / i32-result, no
  memory/globals/imports) — the v0.2 `.cwasm` carries no memory/global/data/table/import sections, so a stateful
  runtime can't be rebuilt from the artefact yet. Non-void/i32 results also deferred (`UnsupportedEntrySignature`).

## Next task (autonomous)

§12.4 — cold-start bench-delta: AOT load + first-call vs JIT first-invocation **≥30%** improvement on ≥3
v1-class hyperfine fixtures (the ADR-0040-deferred §9.8b/8b.3 bench obligation; concrete threshold from
`private/notes/p8-8b3-aot-survey.md`'s 30-50% cold-start estimate). Step 0 survey: the bench harness
(`scripts/run_bench.sh`, `bench/`), how JIT first-invocation is timed today, and whether `zwasm compile` + `zwasm
run *.cwasm` give a clean cold-start measurement point (load+reloc+first-call vs compile+first-call). Bench is
2-host (Mac+Linux) per ADR-0137. Then §12.5 (stack-map section, gated `needs_gc_heap`, per ADR-0117 I4).

## Deferred / open debt (none a Phase-12 blocker)

- **D-250** stateful `.cwasm` runtime reconstruction (memory/globals/imports) + non-void/i32 results — the v0.2
  container lacks the module-state sections; standalone runner is stateless-only. Later §12 / §12+.
- **D-249** Windows bench timing (hyperfine on windowsmini) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn landed §12.3 cross-compile gate (`617a4ae4`): `check_aot_cross_compile.sh` green for all 3 targets +
wired into `gate_merge`. No new code-exec tests (cross-compile is build-only; per-host run already covered by
`runCwasm`). Prior ubuntu verified `8235e6a9` OK (§12.1 close). This turn = build-graph + scripts only, no `src/`
behavior change, so NO ubuntu kick needed (the cross-compile ran locally on Mac; gate_merge runs it 3-host at
merge). Next resume: no ubuntu verification pending. Phase-12 exec tests skip Win64 via `skip.phaseEnd` (D-250);
windowsmini = phase-boundary.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria ~line 1432; §12.3/12.4/12.5 task rows); Phase Status widget.
- ADR-0138 (`.cwasm` v0.2 exports section); ADR-0040/0039 (AOT substrate); ADR-0117 (GC stack-map for §12.5);
  ADR-0067 (3-host); ADR-0136 (`--engine=jit`).
- D-250 (stateful `.cwasm` scope). Survey: `private/notes/p12-12.1-aot-loader-survey.md`.
