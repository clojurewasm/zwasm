# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Recently completed (all DONE; detail in debt.yaml + commits)

- **ADR-0164 trap/crash/exception-diagnostics PROGRAM COMPLETE**: D-293 per-kind JIT trap codes unified
  arm64+x86_64 (demuxed fixup channels); D-292 B-core internal-fault handler (`400c7006`, ADR-0166, exit 70,
  POSIX sigaction + Win VEH); C uncaught_exception(12) (`c2650de5`); D trap-UX audit → D-294 (`partial`).
- D-291 ed25519 JIT oob_table miscompile CLOSED (`23874eda` arm64 callee-saved-home spill fix, guard `9ab34d18`).
- D-287 (`cf605260`, ADR-0165), D-284 (`fbc60815`). All 3-host green.

## ← LEAD: D-290 — 5 sites done; the 3 proposal-laden distillers BLOCKED (tool-output divergence); pivot queue

**D-290 done**: build.zig (`b0bb147a`); regen_test_data.sh (`c43aba23`); deleted regen_v1_carry_over.sh
(`615b9c10`); regen_test_data_2_0.sh (`503fb429`, script-only); regen_spec_1_0_assert.sh (`00d24722`,
i32/i64 unsigned-mask + .wat-aware, test-spec-assert green 212). **HARD BLOCKER found** (debt row D-290 full
detail): the SIMPLE corpora migrate cleanly, but the 3 PROPOSAL-LADEN distillers do NOT. Proven on
regen_wasmtime_misc.sh: upstream is STABLE (old-wabt reproduces committed EXACTLY, basic 72/0 + runtime 266/0),
yet the wasm-tools swap → basic 72/1 + runtime 327/35 = genuine TOOL-OUTPUT divergence, not drift. Concrete:
`memory-copy.1.wasm` validates under wabt but v2 REJECTS the wasm-tools encoding (possible v2 validator gap —
worth its own probe), + wasm-tools emits ~91 more runtime directives → 35 v2 gaps. So `regen_wasmtime_misc.sh`,
`regen_spec_2_0_assert.sh` (912 LOC), `regen_spec_simd_assert.sh` (v128) + dropping flake.nix's wabt pin are
BLOCKED on a direction call: re-curate (drops good coverage — bad) vs keep-wabt (re-scope "one CLI") vs
fix-v2-to-accept-wasm-tools-encoding. wabt STAYS for now. Methodology + recipe preserved in debt row.

**D-290 memory-copy probe CLOSED** (not a v2 gap — wasm-tools' memory-copy.1.wasm = wabt's 219 bytes + a 38B
name section, multi-memory; the failure is distiller tool-swap entanglement, no v2 bug; debt updated).

**D-288 IMPLEMENTED** (`5be983bc`, ADR-0167 option b): `Runtime.checkNativeStackLimit(sp)` (runtime.zig) lazily
computes the per-thread native low limit via `stack_limit.computeStackLimit(INTERP_STACK_HEADROOM=128KB)` and
traps `CallStackExhausted` when `@frameAddress() <= limit`; called at the top of `mvp.invoke()`. New 128KB
interp headroom const (NOT the JIT's 1MB SEH reserve — interp uses an explicit compare, needs only inter-check
margin). Deterministic unit test (set limit, assert sp below/above/disabled). Mac test=0 + zone + lint green;
Mac/Linux behavior UNCHANGED (frame_buf[256] fires first at 2MB << 8MB native limit). **PENDING: Windows gate**
— the binding change is Win64 (~1MB stack → native check fires ~100 deep instead of SEGV). Two things the win
gate must confirm: (1) deep recursion traps cleanly (no SEGV); (2) NO false-trap on normal/shallow programs
(128KB headroom on ~1MB Win stack leaves ~870KB ≈ 100 frames — should be safe). If win RED with false-traps →
the headroom is too large for the actual Win interp stack; lower it. D-288 stays open until win confirms.

**Other queue**: D-290 remainder (3 proposal-laden distillers) direction-gated; D-279 (Win64 heisenbug, streak
3/5, needs win runs). **Prior landed**: D-291 (`23874eda`), D-284 (`fbc60815`). 0 `now` debts. 3 hosts green
@ee940144.

**Other status**: ADR-0164 COMPLETE. **D-294 3-HOST GREEN** (`partial`, residuals polish). **D-279 sha256 lead
FALSE** (corrected — zwasm hashes correctly; fixture has a wrong baked-in constant, golden-matched, never gates;
tracker fail→silent, **streak 3/5**; genuine D-279 = `simd_bit_shift` CRASH only, H3 withdrawn; minor: regen
c_sha256_hash fixture → D-290). Queued: D-288, D-284, D-290.

## Queue (time-consuming first, per user directive)

- **D-288** (interp flat/trampolined recursion OR native-stack-limit check; ADR — interp-architecture redesign).
- **D-291** (paused; see top) · **D-292 B-core** (SIGSEGV→internal-error, needs ADR-0070 amend) · C · D.
- Moderate: **D-284** (interp/jit/aot entry-resolution unify) · **D-290** (wabt→wasm-tools hygiene).
- Defer: **D-289** FP/param/stack large arms · **D-286** (fill/init byte-loop) · **D-285** (JIT bulk-memory, ADR-0153).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** v0.1.0-scope program is
  thoroughly complete + 3-host green (`deb97903`); ADR-0163 bench+docs program ALL DONE. Tag/publish/cutover are
  manual, user-only — there is no release gate.
- Debt ledger: **1 `now`** (**D-295** — D-291 regression guard, not minimally reproducible). **D-291 RESOLVED**
  (`23874eda`, local test-all GREEN). D-294 → `partial` (3-host green, residuals polish). ADR-0164 COMPLETE. Phase 16.

## Step 0.7 (next resume) — verify remote logs (D-288 win64 is the critical one)

- **windows @`<this push>`**: kicked (cadence — Runtime struct field + Win-targeted behavior). CRITICAL: D-288
  native-stack check binds on Win64. Verify `/tmp/win.log` `[run_remote_windows] OK`. If RED with widespread
  trap/exit-1 on normal programs → false-trap (128KB headroom too big for the Win interp stack) → lower
  INTERP_STACK_HEADROOM (stack_limit.zig) or revert 5be983bc. If GREEN → D-288 can close (deep recursion now
  traps cleanly on Win; mark resolved + record cadence). NOT auto-revert on heisenbug (D7).
- **ubuntu @`<this push>`**: kicked (always). D-288 is Mac/Linux-neutral (frame cap fires first) → expect green.



- **ubuntu**: re-kicked @`615b9c10` (new commits regen nop/unreachable wasm-2.0 fixtures — confirms x86_64
  spec-suite green with the regenerated bytes). Prior `a6b3f86f` was GREEN (`OK`, 25437+13351 passed). Next
  resume: verify `/tmp/ubuntu.log` `OK`.
- **windows**: gate kicked @`b0bb147a` last turn was STILL RUNNING at this turn's end (slow per D7) — did NOT
  re-kick to avoid a conflicting run. Next resume: verify `/tmp/win.log` final verdict (`[run_remote_windows]
  OK` = green). NOTE mid-run it showed `failed command: test.exe …--listen` with NO final Build-Summary yet —
  could be the D-279 heisenbug or a real fail; on resume re-run once → reproduces = real Win64 bug (debt+fix),
  flake = `track_heisenbug.sh win64-testall segv` + proceed (D7: NOT auto-revert). The `--__selftest-crash`
  exit-70 + sha256 `verify: FAIL` lines are KNOWN-EXPECTED (selftest / fixture's wrong constant).
- **Gate note**: `run_remote_windows.sh` `OK` line = real green; `Build Summary: N failed` (no `OK`) = RED.
  `zig-host-hello` exit-42 + `--__selftest-crash` exit-70 "failed command" = EXPECTED, not crashes.

## Key refs

- **ADR-0164** (this program: `.dev/decisions/0164_trap_crash_exception_diagnostics_ux.md`). **D-292** (program
  debt row) + **D-291** (ed25519 motivating case) + **D-165** (JIT trap-code infra). ADR-0156 (no autonomous
  release). ADR-0016 (trap stderr / diagnostic phases).
- Surfaces: `src/cli/run.zig` (`surfaceTrap` interp / `surfaceJitTrap` jit+aot / `runWasmJit` / `runCwasmWasi`),
  `src/api/trap_surface.zig` (`jitTrapCode` / `trapMessageFor` / `TrapKind`), `src/cli/main.zig` (`renderFallback`
  trap path), `src/runtime/trap.zig` (Trap set), `src/engine/codegen/shared/entry.zig` (`[d-165]` print),
  `src/engine/codegen/{arm64/emit.zig,x86_64/op_control.zig}` (trap-code write sites), `src/platform/stack_limit.zig`
  (`[stack_probe]` diag). v1 per-kind msgs: `~/Documents/MyProducts/zwasm/src/cli.zig`.
