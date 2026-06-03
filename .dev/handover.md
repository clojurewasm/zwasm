# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **12 IN-PROGRESS — AOT compilation mode**. §12.0 / §12.1 / §12.2 all `[x]`; next `[ ]` = §12.3
  (cross-compile). Phase 11 DONE (`bbc4900b`, 3-host `test-all` reconcile GREEN; WASI 0.1 + bench Mac+Linux per
  ADR-0137 + SIMD gap profile; §11.4 → Phase 15 per ADR-0135).
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

§12.3 — cross-compile (`zig build -Dtarget=x86_64-linux`) + a cross-produced `.cwasm` runs on the target host
(3-host per ADR-0067). The producer already host-arch-tags (`produce.hostArch`); the loader rejects arch
mismatch. Likely shape: produce a `.cwasm` on Mac for the x86_64 target, ship it to ubuntu, `zwasm run` it there.
Step 0 survey: how the gate ships artefacts to remote hosts (`scripts/run_remote_ubuntu.sh`), whether the
producer can target a non-host arch (today `hostArch()` is host-pinned → cross-produce may need a `-Dtarget`
override path). Then §12.4 (cold-start bench-delta ≥30%) + §12.5 (stack-map section, gated `needs_gc_heap`).

## Deferred / open debt (none a Phase-12 blocker)

- **D-250** stateful `.cwasm` runtime reconstruction (memory/globals/imports) + non-void/i32 results — the v0.2
  container lacks the module-state sections; standalone runner is stateless-only. Later §12 / §12+.
- **D-249** Windows bench timing (hyperfine on windowsmini) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn landed §12.1 close: standalone runner `aot/run.zig` (`c7246e3c`) + CLI `.cwasm` branch (`cf983dff`)
+ §12.1 `[x]` + bundle `12.1-aot-cwasm-loader` CLOSED (delta = `zwasm run *.cwasm` → exit 42, smoke + runCwasm
test green). Mac test+lint+zone green; exe builds + real CLI smoke passes. Prior ubuntu verified `22f5be01` OK.
An ubuntu `test` is kicked against this turn's final HEAD → next resume `tail /tmp/ubuntu.log` for OK. Phase-12
exec tests skip Win64 via `skip.phaseEnd` (D-250); windowsmini = phase-boundary.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria ~line 1432; §12.3/12.4/12.5 task rows); Phase Status widget.
- ADR-0138 (`.cwasm` v0.2 exports section); ADR-0040/0039 (AOT substrate); ADR-0117 (GC stack-map for §12.5);
  ADR-0067 (3-host); ADR-0136 (`--engine=jit`).
- D-250 (stateful `.cwasm` scope). Survey: `private/notes/p12-12.1-aot-loader-survey.md`.
