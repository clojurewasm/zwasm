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
- **Cycles-remaining**: ~1 (loader CORE + §12.2 differential DONE; remaining = `zwasm run *.cwasm` CLI wiring,
  blocked on the entry-point design decision below)
- **Continuity-memo**: Step 0 survey → `private/notes/p12-12.1-aot-loader-survey.md`. **Loader DONE**:
  `src/engine/codegen/aot/load.zig` `load()` (parseHeader → arch-check → `jit_mem.alloc`+setWritable → memcpy
  code → parse func metas → `applyRelocs` → setExecutable → `LoadedModule.entry(idx, Fn)`), single-func
  load+execute (`ca69fc68`), 2-func direct-call reloc (`50b4bd1a`; arm64 BL imm26 / x86_64 CALL rel32 patch
  math validated). Registered in `src/zwasm.zig` barrel. **§12.2 differential DONE + `[x]`**: runner_test.zig
  runs real wasm via BOTH JIT (`run{I32,I64}Export`) and AOT (`compileWasm`→`produceFromCompiledWasm`→`load`→
  `setupRuntime`→`entry(0)(&rt)`), asserts equal across: `()→i32` const (`bd138990`), `()→i64` full-width const
  + internal-call reloc through the real pipeline (`d0c1281e`). **NEXT (entry-point ADR, then CLI)**: `zwasm run
  *.cwasm` needs the ENTRY-POINT design — v0.1 `.cwasm` has NO export/name section; `zwasm run` maps
  `_start`/named→func via the export table (run.zig:173). Producer HAS exports in `compileWasm` but discards
  them (not serialised). Options: header `entry_idx` / exports-section (v0.2, ADR-0039 amend) vs `func[0]`
  convention. File a small ADR FIRST (§5/§9-scope-adjacent format change → ADR territory), then wire.
- **Exit-condition**: §12.1 `[x]` when `zwasm run *.cwasm` runs a real artefact end-to-end (loader CORE +
  §12.2 already met; the bundle closes at the CLI wiring).

## Next task (autonomous)

Phase 12 (AOT) IN-PROGRESS. §12.2 differential `[x]` (`d0c1281e` — broadened to i64 full-width + internal-call
reloc through the real produce→load pipeline). §12.1 loader CORE done (`ca69fc68`, `50b4bd1a`). **NEXT** = the
`.cwasm` entry-point ADR (header `entry_idx`/exports-section v0.2 vs `func[0]` convention; the producer currently
discards `compileWasm` exports — run.zig:173 resolves `_start`/named via the export table), THEN `zwasm run
*.cwasm` CLI wiring. §12.1 row `[x]` waits on that CLI end-to-end run; the loader CORE + differential are complete.

## Deferred / open debt (none a Phase-12 blocker)

- **D-249** Windows bench timing (hyperfine on windowsmini / native path) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

Resumed (user re-invoked `/continue`). This turn = §12.2 broadening (`d0c1281e`, Mac green). `/tmp/ubuntu.log`
was absent at resume (machine cycled; not a FAIL) — last verified ubuntu = `a091d0a7` OK (cycle-2a reloc). An
ubuntu `test` is kicked against this turn's final HEAD → next resume `tail /tmp/ubuntu.log` for OK. Phase-12 code
is Mac+ubuntu only (loader exec / differential tests skip Win64 via `skip.phaseEnd`, mirroring jit_mem;
windowsmini = phase-boundary).

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only; run-error = compile passed). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria at line ~1432); Phase Status widget (Phase 11 DONE / 12 IN-PROGRESS).
- ADR-0137 (Windows bench re-scope); ADR-0040/0039 (AOT substrate from §9.8b); ADR-0117 (GC stack-map for AOT).
- Lessons: `2026-06-03-win64-jit-trampoline-arg-marshal-hardcoded-sysv`, `2026-06-03-windowsmini-reconciliation-
  catches-os-only-compile-drift`, `2026-06-03-host-to-jit-must-preserve-callee-saved`.
