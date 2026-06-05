# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** Phases 0–15 + the §16
  surface/safety/docs task-list are DONE. **USER-DIRECTED PROGRAM (2026-06-05) = complete WASI + all-engine + CM.**
  Items 1 (`--invoke` args `34dbebbc`), 2 (WASI 46/46 interp `1d2cb8df`), **3 ALL-ENGINE WASI DONE** —
  JIT (D-244, `71cd3c85`) + **AOT (D-251, `9750b064`, bundle CLOSED this cycle)**. `zwasm run <file.cwasm>` now
  does REAL WASI (`.cwasm` v0.4 serialises import `(module,name,kind)` → `runEntryWasi` rebuilds
  `host_dispatch_base` via `jit_dispatch.lookup` + attaches a WASI Host); a `proc_exit(42)` `.cwasm` exits 42,
  **2-host green (Mac + ubuntu `OK` at `4adc4d5b`)**. Remaining program: **CM (post-v0.1.0)** + the validation
  + GC items below.

## NEXT — validate all-engine WASI on the realworld corpus (extends D-283); investigation-first

The synthetic `proc_exit(42)` proves the AOT-WASI wiring; the dogfooding/completeness step is to run the
**realworld WASI fixture corpus under `--engine aot`** (compile each `.wasm`→`.cwasm`, run, differential vs
interp/wasmtime) to surface concrete gaps (syscalls/memory-state/ops the AOT path doesn't yet handle). **D-283**
already tracks realworld-under-`--engine jit`; widen it to AOT. **Step 0 (investigation-first, no redesign yet)**:
locate the realworld diff_runner (`src/engine/runner_test.zig` / `test/` realworld harness; the interp+jit paths
exist) → add an AOT lane (produce `.cwasm` via `aot/produce.produceFromCompiledWasm`, run via
`cli/run.runCwasmWasi` with stdout capture) → run, triage pass/fail counts → file findings. Likely gaps:
passive data/`memory.init` (AOT §12.3b cycle-1 = active-only), multi-value/non-i32 entry results, unsupported
ops. Each gap = a TDD chunk or a debt row, NOT a silent skip. Bundle when it spans cycles.

**Alternatives if AOT-realworld is quickly green or blocked**: (a) **D-211** precise GcRootMap + AOT-GC —
**verify load-bearing FIRST** (conservative native-stack scan is proven sufficient per ADR-0060; only schedule if
a real false-retention bug/bloat is measured). (b) **Component Model** survey follow-up (A5 survey done; CM is
post-v0.1.0). (c) **D-281** real socket I/O. Pick by concreteness; investigation-first for D-211.

## Step 0.7 (next resume) — verify remote logs

`tail -3 /tmp/ubuntu.log` — was `OK (HEAD=4adc4d5b)`. `tail -3 /tmp/win.log` — windows was kicked this cycle
(cadence: 7 commits); AOT exec is Win64-deferred (`skip.phaseEnd(.win64)`) so it won't exercise the new exec test,
but it verifies the v0.4 format/produce/load tests (run on all hosts) + the rest. Windows red → NOT auto-revert:
re-run once → reproduces = real Win64 bug (debt+fix) else `track_heisenbug.sh`. After a green windows verify run
`bash scripts/should_gate_windows.sh --record`. **DISCIPLINE**: Win64 std `TODO implement … windows` panics only
surface on the actual windows run — reroute the op like `20b9f860`/`f320db6f`.

## Key files (AOT-WASI, just landed)

- `src/engine/codegen/aot/format.zig` — `.cwasm` v0.4 (header 112, `version_v0_4`, `CwasmImport` +
  `writeImportEntry`/`parseImportEntry`).
- `src/engine/codegen/aot/serialise.zig` (`Input.imports`) · `load.zig` (`LoadedModule.imports`, `parseImports`) ·
  `produce.zig` (`collectImports`) · `run.zig` (`runEntryWasi` + `hostDispatchTrap`).
- `src/cli/run.zig` — `runCwasmWasi` (host-attached AOT run); `runCwasm` (compute-only). `cli/main.zig` routes
  `run <.cwasm>` → `runCwasmWasi` (argv + `--dir` preopens threaded).
- `src/wasi/jit_dispatch.zig` — `lookup` (l.559) = the shared WASI name→handler manifest (JIT + AOT).

## Deferred / open debt

- **D-283** realworld corpus under non-interp engines (jit + NOW aot — the NEXT work). **D-211** precise GcRootMap
  (deferred; conservative scan sufficient per ADR-0060 — verify load-bearing before scheduling). **D-282**
  windowsmini configure-phase build flake. **D-279** Win64 SIMD heisenbug (D7-monitored). **D-281** real socket
  I/O. **D-255** C-API WASI io. **D-271** serialize=source-bytes. **D-254** rust 3-OS. **D-249** win bench.

## Key refs

- ROADMAP §16, §11.1 (all-engine WASI DONE), §12.3b (AOT-WASI DONE). ADR-0161 (WASI program) / ADR-0162
  (toolchain). ADR-0156 (endgame, no release). ADR-0039 (`.cwasm`) / ADR-0138 / ADR-0139 / ADR-0140. ADR-0136
  (`run --engine`). ADR-0060 (conservative GC scan sufficient). D-244 (JIT-WASI, the AOT sibling).
