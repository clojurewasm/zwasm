# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (完成形) — §16.1–16.7 task-list COMPLETE; the loop CONTINUES, no release (ADR-0156).** Phases 0–15
  + the entire §16 surface/safety/docs task-list are DONE. The v2 redesign has hit the 完成形 bar: clean design +
  lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces (C/Zig/CLI). **The loop never
  tags/publishes/cuts over** (manual user-only); it now keeps refining + paying backlog debt **indefinitely**.
  Phase Status widget stays Phase-16 IN-PROGRESS (completion-finalization is open-ended, not a closeable phase).
- **§16 outcomes** (detail in the ROADMAP §16 rows + ADRs + CHANGELOG): **§16.1** migration guide (`58a483e8`);
  **§16.2** C-API **gap 0 (293/293)** (`e9367bb2`, `scripts/capi_surface_gap.sh`); **§16.3** Zig-API facade
  confirmed minimal/clean (ADR-0025→0109); **§16.4** CLI = **run+compile** + --version/--help (ADR-0159);
  **§16.5** dogfooding — external consumability fixed + Global/Table accessors (D-272 closed), full facade proven
  via `examples/zig_dep/`; **§16.6** GC-on-JIT memory-safe — collect trigger + adversarial UAF test green
  Mac+x86_64 (ADR-0160); **§16.7** docs — README/CHANGELOG/`docs/reference/`/`docs/tutorial.md` to the settled
  surface (`12390815`, `3a5e8ba0`).

- **WASI preview1 46/46 DONE (`1d2cb8df`), verified Mac + x86_64-Linux (ubuntu `OK HEAD=f9a09b3e`, 25437/0).**
  Full interp surface; D-278 discharged; sockets=notsock + real socket I/O = D-281. windows = D-282 env-flake
  (all-runners-0-failed + configure-phase FileNotFound = green-for-correctness).

## Active bundle

- **Bundle-ID**: jit-wasi (D-244)
- **Cycles-remaining**: ~2
- **Continuity-memo**: 🎯 **`zwasm run --engine jit <prog>` does REAL WASI end-to-end** — prints (smoke: jithello +
  c_hello_wasi), exits with the guest code (`proc_exit(42)`→42), and sees argv (`argc.wasm a b`→3). **The whole
  common WASI startup surface is JIT-wired by reusing the interp handlers (no re-impl)**: `JitRuntime.wasi_host`
  field (`dec5e84f`) + `runI64/VoidExportWasi` primitives (`d761637f`/`088c3b23`) + clock/random (`dec5e84f`/
  `8d1b7612`) + fd_write/fd_read (`81b3e1d3`/`20392074`) + runWasmJit owns a Host w/ io+argv (`0c3e4cef`/`cd10a3b6`,
  main.zig threads both) + proc_exit exit-code (`1b01061f`) + args/environ (`cd10a3b6`). **Plus a PRE-EXISTING CLI
  bug fixed (`f320db6f`): shared fd_write only wrote to a capture buffer → `zwasm run` (interp AND jit) silently
  DROPPED stdout; now routes to real std.Io.File.stdout()/stderr() when no buffer + io.** **NEXT (bundle's last
  push): (1) register the other ~37 WASI syscalls in `jit_dispatch.zig:lookup`** (only ~13 names there now → file
  ops like path_open/fd_seek/fd_filestat_get TRAP on JIT). Each = a thin JIT thunk (GPR args → shared handler, the
  proven pattern) + a `lookup` entry. The shared handlers already exist; this is mechanical (~37, batch in chunks).
  **(2) `--dir` preopens for JIT** (runWasmJit takes no preopens; thread them + open dirs onto the Host fd_table like
  runWasmCapturedOpts). Then a JIT file-op program works. Win64 JIT-exec tests gate `skip.phaseEnd(.win64)`;
  real-stream test uses fd 2 (fd 1 corrupts zig-test protocol).
  **D-251 AOT-WASI** (separate, later) needs `.cwasm`
  v0.3 import-metadata serialization (`aot/format.zig`) first. **DISCIPLINE: cross-compile windows-gnu; trust ubuntu
  for Linux-runtime divergence; read win crash lines (std Win64 TODOs only show at runtime).**
- **Exit-condition**: a JIT-run WASI module does REAL I/O (e.g. `clock_time_get` nonzero + `fd_write` to real stdout
  + file ops via preopen) — JIT WASI handler count grows 9 → meaningful subset, green Mac + ubuntu.

## NEXT — USER-DIRECTED PROGRAM 2026-06-05 (supersedes the bucket-3 plateau): complete WASI + all-engine + CM

The prior finalization items are DONE (C-API funcref D-269 = owned-handle `of.ref`, `01c1d0cb`, bundle D-269B
closed; verified x86_64 `OK HEAD=2ea7c187`). A new **user-directed program** (chat 2026-06-05) is now the active
work — **ADR-0161** (WASI completion) + **ADR-0162** (toolchain carve-out). Ordered:

- **A — 整備 DONE (prior session)**: rust on test hosts; ADR-0161/0162/0076-D7; §11.1 corrected (**WASI=21/46**);
  A5 CM survey + A1-wire 3-OS rust DONE; **D-279 Win64 SIMD heisenbug** (intermittent, monitored by D7).
- **1. D-273(1) `--invoke NAME=ARGS` args + typed result — ✅ DONE (`34dbebbc`)** (interp; `src/cli/invoke_args.zig`).
- **2. D-278 WASI preview1 21→46 (interp) — ✅ 46/46 COMPLETE (`1d2cb8df`), verified Mac+ubuntu, D-278 discharged.**
- **3. All-engine WASI — 🔵 ACTIVE (see `## Active bundle` jit-wasi / D-244 JIT first, then D-251 AOT).** Make the
  46 syscalls run under JIT/AOT, not just interp. **4. Precise GC root + AOT-GC** (D-211; verify load-bearing first).
- **Post-v0.1.0**: Component Model / WASI P2 (A5 survey informs). WASI 0.3/async (ClojureWasmFromScratch agent ref).

**ADR-0076 D7 (windows cadence gate)**: the loop now HONORS `should_gate_windows.sh` (run windows たまに — ABI-risk
diff OR ≥4 commits, NOT per-turn/too-slow, NOT phase-boundary/too-rare). Win64 red = heisenbug-classify (re-run),
no auto-revert. Step 6+7: `should_gate_windows.sh` exit 0 → kick `run_remote_windows.sh test-all` + `--record`.

## Step 0.7 (next resume) — verify per-cadence remote logs

ubuntu GREEN at `a15b9926` (proc_exit). This turn pushed D-244 args/environ + argv threading (`cd10a3b6`);
re-kicked both. **Step 0.7 next resume:
`tail /tmp/ubuntu.log` (must be OK, auto-revert on FAIL) + `tail /tmp/win.log` — distinguish the D-282 env-flake
(ALL runners 0-failed + only `configure phase FileNotFound`) from a REAL crash (`' exited with code N`/`panic`/
`TODO implement ... windows` + a named test). A std Win64 `TODO`-panic in an op I use → reroute like `20b9f860`.**
**DISCIPLINE: cross-compile windows-gnu (catches compile gaps); Win64 runtime panics (std TODOs) only surface on
the actual windows run — read the crash line.** **Gate**: Mac = `mac_gate.sh`; ubuntu = always (D6); windows = cadence (D7).

## Deferred / open debt (D-274/275/276/257 discharged this session — removed)

- **Memory-safety (§16.6 DONE, verified 2-host; D-276 proven by ADR-0060)** — only residual is **D-211** precise
  GcRootMap (deferred; conservative scan proven sufficient meanwhile). **D-210** cohort root fix (D-142/206/210/245).
- **Surface residuals** — **D-273** now `note`: (1) `--invoke` args DONE (`34dbebbc`); (2)-(5)
  `--env`/`--fuel`/`--timeout`/`--wasi` deferred-pending-need. **D-253** ref machinery (incl. D-253-D
  standalone-copy; owned-handle `of.ref` model). **D-271**
  serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
