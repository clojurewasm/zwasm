# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** Phases 0–15 + the §16
  surface/safety/docs task-list are DONE. Now executing the **USER-DIRECTED PROGRAM (2026-06-05)**: complete
  WASI + all-engine + CM. Items 1 (`--invoke` args, `34dbebbc`), 2 (WASI 46/46 interp, `1d2cb8df`), 3-JIT
  (D-244, 3-host green `71cd3c85`) are DONE. **NOW: item 3-AOT = D-251 (AOT-WASI)** — make
  `zwasm run <file.cwasm>` resolve + run WASI imports.

## Active bundle

- **Bundle-ID**: D-251-aot-wasi (`.cwasm` v0.4 imports-metadata → standalone WASI run)
- **Cycles-remaining**: ~2
- **Continuity-memo**: `.cwasm` was compute-only (no import metadata). Plan: format v0.4 imports section ✅ →
  produce+load ✅ → **run-wire (host_dispatch_base + rt.wasi_host)** → CLI route `run <.cwasm>` + WASI. The
  run-wire mirrors `cli/run.zig:runWasmJit` (build `wasi_host.Host`, set io/argv/preopens) + `setup.zig`'s
  dispatch construction (alloc `[]usize` sized to func-import count, pre-fill default trap, `jit_dispatch.populateDispatch`
  from `mod.imports`, set `rt.host_dispatch_base`/`_count` + `rt.wasi_host`). proc_exit unwinds via JIT trap →
  catch Error.Trap, read `host.exit_code` (see runWasmJit). populateDispatch wants `[]sections.Import` but reads
  only module/name/kind → reconstruct from `mod.imports` with placeholder payload.
- **Exit-condition**: a CLI-level test where `zwasm run <hello.cwasm>` does REAL WASI (fd_write→captured stdout
  bytes match, or proc_exit code surfaces) end-to-end, 2-host green.
- **Progress**: chunk 1 format v0.4 (`0f693b98`) ✅ · chunk 2 produce+load imports (`9f13e8e4`) ✅ ·
  **NEXT = chunk 3 run-wire** in `src/engine/codegen/aot/run.zig` (`runEntryWasi`).

## Step 0.7 (next resume) — verify remote logs

D-244 was 3-host GREEN at `71cd3c85`; no remote pending at bundle start. After the turn's push, `tail -3
/tmp/ubuntu.log` (always) + `/tmp/win.log` (cadence). **DISCIPLINE**: cross-compile windows-gnu (catches compile
gaps); Win64 std `TODO implement … windows` panics only surface on the actual windows run — reroute the op like
`20b9f860`/`f320db6f`. The AOT exec tests are Win64-deferred (`skip.phaseEnd(.win64)`, mirrors aot/load.zig).

## Key files (D-251)

- `src/engine/codegen/aot/format.zig` — v0.4 (header 112, `version_v0_4`, `CwasmImport` +
  `writeImportEntry`/`parseImportEntry`).
- `src/engine/codegen/aot/serialise.zig` — `Input.imports`; writes imports section (step 9).
- `src/engine/codegen/aot/load.zig` — `LoadedModule.imports: []ImportMeta`, `parseImports`.
- `src/engine/codegen/aot/run.zig` — **NEXT**: `runEntryWasi` (host_dispatch + wasi_host wiring).
- `src/wasi/jit_dispatch.zig` — `populateDispatch(dispatch, []sections.Import)` (l.626), `lookup` (l.559); find
  the default trap trampoline setup.zig pre-fills the dispatch array with.
- `src/cli/run.zig` — `runCwasm` (compute-only now); `runWasmJit` (the host-build pattern to mirror).
- `src/engine/setup.zig` — JIT dispatch-array construction (the alloc+populate+attach pattern).

## Deferred / open debt

- **D-251** = THIS bundle (AOT-WASI). **D-283** realworld corpus under `--engine jit`. **D-211** precise GcRootMap
  (deferred; conservative scan sufficient). **D-282** windowsmini configure-phase build flake (Defender/.zig-cache
  race). **D-279** Win64 SIMD heisenbug (D7-monitored). **D-281** real socket I/O. **D-255** C-API WASI io.
  **D-271** serialize=source-bytes. **D-254** rust 3-OS. **D-249** win bench.

## Key refs

- ROADMAP §16, §11.1 (WASI). ADR-0161 (WASI completion program) / ADR-0162 (toolchain). ADR-0156 (endgame, no
  release). ADR-0039 (`.cwasm` format) / ADR-0138 (exports) / ADR-0139 (v0.3 globals/mem/table). ADR-0136
  (`run --engine`). D-244 (JIT-WASI, the sibling pattern AOT mirrors).
