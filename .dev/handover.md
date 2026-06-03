# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **12 IN-PROGRESS — AOT compilation mode** (Phase 11 DONE 2026-06-03; widget advanced). Phase 11 =
  WASI 0.1 full + bench infra + SIMD gap profile, closed at `bbc4900b` with the 3-host `test-all` reconcile GREEN.
- **§11 close**: §11.1 (WASI, incl. Windows realworld subset) / §11.2 (bench, Mac+Linux) / §11.3 (SIMD gap ✓) /
  §11.P all `[x]`. §11.4 → Phase 15 (ADR-0135). **Bench re-scoped to 2-host** (Mac+Linux) per **ADR-0137**:
  hyperfine absent on windowsmini (native zig.exe, no nix shell; not autonomously provisionable) → Windows bench
  *timing* deferred to **D-249** (correctness reconcile unaffected).
- **11.P-win64-jit bundle CLOSED** (`bbc4900b`, windowsmini run-2 GREEN — zero crashes across 50131 lines): the
  §11.P windowsmini reconcile surfaced Phase-10 EH/GC-on-JIT bugs on the Win64 ABI (first Win64 run since §11.1).
  Fixed + verified: (1) 15 GC/EH emit files hardcoded SysV arg regs → `abi.current.arg_gprs[]` (cycle-1, ≤4-arg);
  (2) 6 ≥5-arg array ops → `gc_marshal.routeArg` stack-spill + `computeOutgoingMaxBytes` Win64 shadow/stack
  reservation (cycle-2, ex-D-248); (3) throw_trampoline Win64 test-wrapper RSP 16-byte parity (`subq/addq $8`).
  All SysV-no-op (Mac+ubuntu green throughout). Lesson:
  `2026-06-03-win64-jit-trampoline-arg-marshal-hardcoded-sysv`.
- **3-host invariant RESTORED**: Mac aarch64 + ubuntunote x86_64-SysV + windowsmini x86_64-Win64 all GREEN.

## Active bundle

- **Bundle-ID**: 12.1-aot-cwasm-loader
- **Cycles-remaining**: ~2 (cycle-1 = load.zig MVP: parse + alloc + copy + reloc + execute, unit test green;
  cycle-2 = `zwasm run *.cwasm` CLI wiring + AOT↔JIT differential §12.2)
- **Continuity-memo**: Step 0 survey → `private/notes/p12-12.1-aot-loader-survey.md`. **CYCLE-1 DONE
  (`ca69fc68`; Mac test + zone + lint clean)**: `src/engine/codegen/aot/load.zig` — `load()` (parseHeader →
  arch-check → `jit_mem.alloc`+setWritable → memcpy code section → parse func metas → `applyRelocs` (no-op for
  0 relocs) → setExecutable → `LoadedModule.entry(idx, Fn)`); MVP test produces a `()→i32` const-7 `.cwasm` via
  `serialise.produceCwasm`, loads, executes → returns 7 (+ arch-mismatch + truncated-header reject tests).
  Registered in `src/zwasm.zig` barrel. **CYCLE-2a DONE (`50b4bd1a`)**: 2-func direct-call reloc test —
  `applyRelocs` validated end-to-end (func0 BL/CALLs func1→7, propagates; arm64 STP/LDP frame, x86_64 stack
  CALL). The blind-written BL imm26 / CALL rel32 patch math is correct (Mac green; ubuntu verifies x86_64).
  **CYCLE-2b DONE (`bd138990`)**: §12.2 AOT↔JIT differential test (runner_test.zig) — a real `()→i32` wasm run
  via BOTH JIT (`runI32Export`) and AOT (`compileWasm`→`produceFromCompiledWasm`→`load`→`setupRuntime`→
  `entry(0)(&rt)`), both = 7, asserted equal. Validates produce→load round-trip is execution-faithful through
  the full pipeline. **NEXT**: (a) broaden §12.2 fixtures (params / i64 / multi-func-with-call) to harden the
  differential; (b) `zwasm run *.cwasm` CLI — needs the ENTRY-POINT design first (v0.1 `.cwasm` has NO export/
  name section; `zwasm run` maps `_start`/named→func via the export table per run.zig:173). Options: header
  `entry_idx`/exports section (v0.2, ADR-0039 amend) vs `func[0]` convention — a Phase-12 design decision (small
  ADR) before wiring. Survey: producer has exports in `compileWasm` but discards them (not serialised).
- **Exit-condition**: `load.zig` loads a `serialise.produceCwasm`-produced `.cwasm` + executes func[0] → the
  asserted i32 (MVP behavior signal); §12.1 `[x]` when `zwasm run *.cwasm` runs a real artefact end-to-end.

## Next task (autonomous)

Phase 12 (AOT) IN-PROGRESS. AOT loader (`load.zig`) DONE + 2-host green: single-func load+execute (`ca69fc68`),
multi-func direct-call relocs (`50b4bd1a`), §12.2 AOT↔JIT differential (`bd138990`). **LOOP STOPPED at user
request at this clean breakpoint** (2026-06-03, after §12.2). **NEXT on resume** = (a) broaden §12.2 fixtures
(params / i64 / multi-func-with-call differential); (b) `zwasm run *.cwasm` CLI — first a small ADR for the
`.cwasm` entry-point (header `entry_idx`/exports-section v0.2 vs `func[0]` convention; run.zig:173 maps
`_start`/named via the export table the producer currently discards). Active bundle continuity-memo has the full
detail. The §12.1 row `[x]` waits on the CLI wiring; the loader CORE is complete.

## Deferred / open debt (none a Phase-12 blocker)

- **D-249** Windows bench timing (hyperfine on windowsmini / native path) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

Loop STOPPED at user request after §12.2 (`bd138990`). An ubuntu `test` was kicked against the final HEAD
(`3ce4f567`) for the §12.1/§12.2 loader-test verification → on resume, `tail /tmp/ubuntu.log` for
`[run_remote_windows]`-style OK (expect green; the loader differential ran green on Mac). Prior verified: ubuntu
`a091d0a7` OK (cycle-2a reloc). Phase-12 code so far is Mac+ubuntu only (loader exec tests skip Win64 via
`skip.phaseEnd`, mirroring jit_mem; windowsmini = phase-boundary). No re-arm (user stop).

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only; run-error = compile passed). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria at line ~1432); Phase Status widget (Phase 11 DONE / 12 IN-PROGRESS).
- ADR-0137 (Windows bench re-scope); ADR-0040/0039 (AOT substrate from §9.8b); ADR-0117 (GC stack-map for AOT).
- Lessons: `2026-06-03-win64-jit-trampoline-arg-marshal-hardcoded-sysv`, `2026-06-03-windowsmini-reconciliation-
  catches-os-only-compile-drift`, `2026-06-03-host-to-jit-must-preserve-callee-saved`.
