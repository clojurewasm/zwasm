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

## Active bundle

- **Bundle-ID**: D-283-aot-realworld (AOT-WASI realworld differential validation)
- **Cycles-remaining**: ~1
- **Continuity-memo**: Chunk 1 DONE (`a81a388e`) — opt-in `--aot` lane in `diff_runner.zig` (compile→`.cwasm`→
  `runCwasmWasi` w/ new `stdout_capture` param) behind a separate `test-realworld-diff-aot` target (NOT default —
  JIT-compiles every fixture, slow + in-process exec). Report-only. **Investigation finding**: `c_hello_wasi`
  traps under AOT — BUT it ALSO traps under `--engine jit` (exit 1, argv-over-read stress fixture; a pre-existing
  v2-vs-wasmtime gap, NOT AOT-specific); `c_bitwise_ops` AOT-MATCHed. So AOT mirrors JIT correctly. **NEXT**: run
  the full `zig build test-realworld-diff-aot` (slow, launched in bg → `/tmp/d283_aot_full.log`), confirm NO genuine
  `MISMATCH-AOT` (a fixture that AOT ran clean but bytes differ from wasmtime = real bug), tally AOT coverage vs the
  interp lane. Then either gate the AOT lane (if clean) or debt-row the residual AOT-unsupported set.
- **Exit-condition**: full corpus AOT-lane run completes; 0 genuine `MISMATCH-AOT`; AOT match-count documented vs
  interp; decision (gate vs debt-row) recorded.

**After the bundle (next program items)**: (a) **D-211** precise GcRootMap + AOT-GC — **verify load-bearing FIRST**
(conservative native-stack scan proven sufficient per ADR-0060; only schedule if a real false-retention bug/bloat
is measured). (b) **Component Model** survey follow-up (A5 done; CM post-v0.1.0). (c) **D-281** real socket I/O.

## Step 0.7 (next resume) — verify remote logs

`tail -3 /tmp/ubuntu.log` — chunk 1 (D-283) changed `runCwasmWasi` sig + diff_runner + build.zig → ubuntu re-kicked
this turn; expect `OK`. **Windows D-028 was RESOLVED**: HEAD 4adc4d5b first run hit the D-028 hang (`test runner
failed to respond`, spec-trap runner, ~6% Defender flake), re-run came back `[run_remote_windows] OK` (55/55
realworld passed) — flake confirmed, `track_heisenbug d028 silent` (streak 1), cadence recorded at `8d081c77`.
D-251 AOT-WASI is **3-host green**. windows now on cadence (`should_gate_windows.sh`). **DISCIPLINE**: Win64 std
`TODO implement … windows` panics only surface on the actual windows run — reroute the op like `20b9f860`.

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
