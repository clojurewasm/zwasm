# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** Phases 0–15 + the §16
  surface/safety/docs task-list are DONE. **USER-DIRECTED PROGRAM (2026-06-05) = complete WASI + all-engine + CM.**
  Items 1 (`--invoke` args `34dbebbc`), 2 (WASI 46/46 interp `1d2cb8df`), **3 ALL-ENGINE WASI DONE** —
  JIT (D-244, `71cd3c85`) + **AOT (D-251, `9750b064`)**. `zwasm run <file.cwasm>` does REAL WASI (`.cwasm` v0.4
  serialises import `(module,name,kind)` → `runEntryWasi` rebuilds `host_dispatch_base` via `jit_dispatch.lookup`
  + attaches a WASI Host); D-251 **3-host green** (proc_exit(42)→42; Mac + ubuntu + windows). AOT-WASI **validated
  on the realworld corpus** (D-283 lane: 7/7 byte-match wasmtime, 0 mismatch). Remaining program: **CM
  (post-v0.1.0)**; otherwise Phase-16 debt/dogfooding.

- **D-283-aot-realworld bundle CLOSED this cycle**: opt-in `test-realworld-diff-aot` AOT differential lane
  (`a81a388e` + `d7e3f131`, <64KB fixture cap). **AOT byte-matches wasmtime on 7/7 runnable realworld fixtures,
  0 `MISMATCH-AOT`** — confirms AOT-WASI output ≡ wasmtime where the engine runs (large libc/Go guests = SKIP-LARGE,
  trap under `--engine jit` anyway). D-283 stays open for a subprocess-based full-corpus differential (the
  in-process lane can't per-fixture-timeout the slow JIT-compiles).

## NEXT — completion plateau: marginal refinements only; big-ticket = v0.2.0 (user-scoped)

**The v0.1.0-scope program is COMPLETE + validated + hardened.** WASI 46/46 (interp+JIT+AOT), all-engine
validated on the realworld corpus (D-283, 7/7 byte-match), scaffolding audited clean (`6a9d4b56`, 0 block), debt
clean (0 `now`, ledger 59), all 完成形 dimensions met (D-265 perf rework CLOSED 2026-06-04 — no measured
deficiency). AOT-WASI hardened this cycle: **fd_write→stdout-capture** (`9d0c60e8`) + **`--dir` preopen
fd_prestat_get** (`3383bf7d`) unit tests in `zig build test` (beyond the proc_exit dispatch test).

**Honest state**: the substantive remaining work is **v0.2.0-scope, ROADMAP-deferred** (§3 lines 117/223/224:
"Component Model + WASI 0.2 — large surface, deferred to v0.2.0"; "CM = v0.2.0 entry point") — pulling it into
scope is a scope-expansion decision that **needs user direction**, not autonomous work. The other "remaining"
items are NOT clean `now` work: **D-281** sockets = on-demand (notsock is spec-conformant; building ahead of
demand = over-engineering); **D-255** C-API io = deliberate ADR-0143 v0.1 scope deferral (blocked-by a C-API io
construct); **D-266** = optional confirmation (D-265 already closed). D-211 = confirmed deferred (ADR-0148/0060).

**So next cycle**: keep finding *marginal* in-scope refinements (more AOT-WASI syscall hardening tests; doc polish;
`note`-debt-row staleness reconciliation) and re-arm — per ADR-0156 the loop refines indefinitely. Do NOT chase
D-281/D-255/CM as if `now` work; surface to the user only if a genuine bucket-3 (all marginal work exhausted).
The big lever (v0.2.0 / CM / WASI-0.2) awaits a user scope decision.

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
