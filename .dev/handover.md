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
- **Continuity-memo**: Step 0 survey DONE → `private/notes/p12-12.1-aot-loader-survey.md` (format shapes,
  section order, reloc-apply REUSE of `linker.zig:291-337`, exec contract, MVP recipe). NEXT = write
  `src/engine/codegen/aot/load.zig` + its red test: produce a `()→i32` const-7 `.cwasm` via
  `serialise.produceCwasm` (confirm its exact input API first), `load()`, cast entry(0) to
  `*const fn(*JitRuntime) callconv(.c) i32`, invoke, assert 7. REUSE the JIT linker's reloc patch (encBL/
  patchRel32) + `jit_mem.alloc/setExecutable`. Divergence: keep `.cwasm` immutable (eager copy-and-patch into
  a runtime JitBlock; NOT v1 in-file patching).
- **Exit-condition**: `load.zig` loads a `serialise.produceCwasm`-produced `.cwasm` + executes func[0] → the
  asserted i32 (MVP behavior signal); §12.1 `[x]` when `zwasm run *.cwasm` runs a real artefact end-to-end.

## Next task (autonomous)

Phase-11 CLOSED (`c4cc74cc`); Phase 12 (AOT) open. §12.1 Step 0 survey DONE (note above). **NEXT** = §12.1 Step 2
red test → Step 3 `load.zig` MVP, per the Active bundle. Producer substrate at
`src/engine/codegen/aot/{format,serialise,produce}.zig`; reloc-apply reused from `linker.zig`.

## Deferred / open debt (none a Phase-12 blocker)

- **D-249** Windows bench timing (hyperfine on windowsmini / native path) — perf-completeness only, ADR-0137.
- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void fixed; win64 + arg'd variants = remainder.
- **D-246** §11.3 arm64 dot/extmul JIT-emit hole → Phase 15. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free (partial). D-210/D-234/D-237/D-229/
  D-231/D-204/D-209/D-213 (note).

## Step 0.7 (next resume)

This turn closes Phase 11 (docs-only flips + ADR-0137 + D-249 + lesson) → no new code, so no gate kick needed for
the close commits (ubuntu+windowsmini already GREEN on the code at `bbc4900b`). If Phase-12 code lands later this
turn, kick ubuntu vs the final HEAD. Prior verified: ubuntu `bbc4900b` OK + windowsmini run-2 `bbc4900b` OK.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only; run-error = compile passed). 3-host reconcile = phase boundary.

## Key refs

- ROADMAP §12 (AOT — Goal + exit criteria at line ~1432); Phase Status widget (Phase 11 DONE / 12 IN-PROGRESS).
- ADR-0137 (Windows bench re-scope); ADR-0040/0039 (AOT substrate from §9.8b); ADR-0117 (GC stack-map for AOT).
- Lessons: `2026-06-03-win64-jit-trampoline-arg-marshal-hardcoded-sysv`, `2026-06-03-windowsmini-reconciliation-
  catches-os-only-compile-drift`, `2026-06-03-host-to-jit-must-preserve-callee-saved`.
