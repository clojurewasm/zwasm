# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active program — ADR-0164: trap / crash / exception diagnostics & UX (D-292)

JIT/AOT printed a bare `Trap` (no kind) where v1 + v2-interp give per-kind messages — a v1-parity
regression (surfaced by D-291). Audit-first, spans engines; four workstreams **A→B→C→D**, then D-291:

- ✅ **A — surface the trap KIND + message on ALL engines. DONE.**
  - CLI surface (`b6da8604`): JIT/AOT run paths thread `trap_kind` → `trap_surface.jitTrapCode` → per-kind CLI
    message; single-message interp-parity (double-`Trap` bug fixed, genuine trap = exit 1 not re-raised).
  - **Codegen widening DONE for the common 4** (per-kind stub + per-kind fixup channel demuxed from
    `bounds_fixups`; arm64 `EmitCindStub` / x86_64 `emitTrapExitStub`): A1 `6fcbabbd` unreachable=5 ·
    A2 `687d1a73` div_by_zero=7 + div_s overflow=8 (fixed a latent x86_64 overflow→div-by-zero misreport) ·
    A3 `63e8c6eb` oob_memory=6 (memory load/store + bulk + v128). All UNIFIED across arm64+x86_64.
  - The OTHER still-generic kinds (oob_table / invalid_conversion / trunc int_overflow / null_reference /
    cast_failure / array_oob — `bounds_fixups` is a multi-kind catch-all) are **D-293** (kinded-fixup refactor),
    deferred behind B/C/D. Trap-kind execution tests live in `src/engine/runner_trap_test.zig` (new this turn).
- **B — crash-vs-trap distinction. IN PROGRESS.**
  - ✅ diag hygiene (`80cba28a`): `[stack_probe]` + `[d-165] kind=4` prints gated behind `-Dtrace-stackprobe`
    (default false) → clean Debug test stderr; D-279/D-165 primitives preserved (opt-in). Step-0 CORRECTED the
    handover's premise — these are setup-time once-per-process Debug prints, NOT per-trap stub context.
  - **B core (deferred behind D-291): internal SIGSEGV/@panic → graceful INTERNAL ERROR.** Step-0 finding:
    NO signal handling anywhere (`grep` cli/+entry = empty) — an internal fault hits the OS as raw signal 11
    (exit 139), undistinguished from a clean wasm `Trap`. Fix = a `sigaction`/vectored-exception handler (any
    such signal in v2 = internal bug, since v2 uses NO signal-based wasm semantics — all traps are explicit
    checks) surfacing a distinct "internal error". NEEDS an **ADR-0070 (libc) amendment** + design ADR; bundle.
- **C — exception(EH)-vs-trap distinction.** · **D — audit vs wasmtime/wasmer/WasmEdge/v1 → gap list.**
- **D-291** (ed25519 `oob_table` miscompile, A-unblocked) — exhaustively localized this session, **PAUSED for
  fresh context** (see the D-291 section above + debt row). B-core/C/D remain (B-core needs an ADR-0070 amend).

DISCHARGE (D-292): all engines emit clear per-kind trap messages + crash/trap/exception cleanly distinguished +
audit-gap list closed-or-deferred.

## Recently completed (breadth, pivot from D-291)

- ✅ **D-287 DONE** (`cf605260`, ADR-0165): `zir.max_control_stack` 1024→4096 (deeply-nested switch.wasm now
  validates). **D-288** (queued): interp recurses NATIVELY, `frame_buf[256]` is a SEGV guard; real fix = flat/
  trampolined interp OR native-stack-limit check (ADR) — see queue.

- ✅ **ADR-0164 trap-crash-exception-diagnostics PROGRAM COMPLETE** (full detail in debt.yaml D-292/D-293 +
  commits; this session's body of work):
  - **D-293** (slices 1–4d): per-kind JIT trap codes unified arm64+x86_64 via demuxed fixup-channels —
    oob_table(2)/cind_sig(3)/trunc-overflow(8)/invalid_conversion(9)/null_reference(10)/array_oob(6)/cast_failure
    (11); slice-4a also fixed the INTERP surface (null/cast/uncaught were `binding_error`) + a latent arm64
    call_ref→oob_table mis-report. runner_trap_test per kind (JIT+interp parity). GC trampolines/i31 deferred.
  - **D-292 B-core** (`400c7006`, ADR-0166, bundle closed): production internal-fault handler — internal SIGSEGV
    → `zwasm: internal error …` + **exit 70** (vs trap exit 1 / silent crash). POSIX sigaction + Windows VEH
    (`First=1`, the gate caught it losing to Zig's default); `test-internal-fault` 3-host green. Lesson filed.
  - **D-292 C** (`c2650de5`): JIT uncaught throw/throw_ref → uncaught_exception(12); fixed a latent x86_64
    →unreachable(5) mis-report. **D** (`4bdaec59`): trap-UX audit vs wasmtime/wasmer/v1 — clean, ADR-0159-aligned;
    one bug found → **D-294** (JIT call_indirect null-elem → mislabels indirect_call_mismatch; fix = code 13).

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

**D-288 STARTED** (the biggest substantive item): Phase I investigation done (subagent) + DECISION made
(ADR-0167): **option (b) native-stack-limit check in interp `invoke()`** (mirror JIT ADR-0105 probe), NOT the
flat-interp rewrite — option (a) rejected (would let slow interp out-recurse the native-recursing JIT = engine
asymmetry; spec mandates no min depth). Fixes the latent Win64 SEGV (1MB stack → ~128 real limit < the 256
guard). **NEXT (D-288 Phase II→IV)**: (1) char-test pinning clean CallStackExhausted trap on deep-but-bounded
recursion (Mac) + a Win-ceiling fixture; (2) add `checkNativeStackLimit()` (reads `@frameAddress()`, compares
`stack_limit.computeStackLimit(headroom)`) at `invoke()` top (mvp.zig:654); (3) 3-host green, esp. Win64
no-SEGV. Mechanism+anchors in debt row D-288 + ADR-0167.

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

## Step 0.7 (next resume) — verify remote logs

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
