# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: D-291-ed25519-cind-miscompile
- **Cycles-remaining**: ~2 (needs a gated codegen diagnostic, then bisection)
- **Continuity-memo**: ed25519 JIT traps `oob_table` = inline **call_indirect** bounds (code 2), index ≥2 into
  a 2-slot table. All 3 cind sites: index = `i32.const 0; i32.load offset=16777416` (data seg inits that addr
  to **1**). **6 minimal repros ALL pass (JIT==interp)** — ruled OUT: large-offset load, single/same-addr/exact
  overlapping data segs, no-store-targets-0x1000028, the cind-index-from-load pattern. ⇒ a CONTEXT-DEPENDENT
  regalloc/spill miscompile (load-base `i32.const 0` or the index corrupted at ed25519's scale), NOT memory/
  data/cind-lowering. Structural minimal repros EXHAUSTED. NEXT (fresh-context): add a gated (`-Dtrace-stackprobe`,
  arm64-ok) diag to the INLINE cind path — `op_call.zig` cind_bounds_fixups ~L398: store the index reg → a new
  `JitRuntime.trap_aux` (jit_abi.zig, add at struct END to keep offsets) before the B.HS; print in entry.zig
  when trap_kind==2 → capture the ACTUAL bad index + which of the 3 cind sites; then trim ed25519's call graph.
  Repros: regen `/tmp/d291*.wat` from the D-291 row. Full lead: D-291.
- **Exit-condition**: culprit interaction identified + a minimal `.wat` fixture reproduces the oob_table trap on
  JIT (passes interp); fix lands; ed25519 `--engine jit` matches wasmtime (exit 0).

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
- **← LEAD (D-291, A-unblocked): ed25519 JIT `oob_table` miscompile** — the program's MOTIVATING case, now a
  concrete narrowed bug (see Active bundle above + D-291 row). Prioritised ahead of B-core/C/D (a real
  correctness bug > polish/audit). The trap is a clean wasm trap (call_indirect bad index), not a SIGSEGV.

DISCHARGE (D-292): all engines emit clear per-kind trap messages + crash/trap/exception cleanly distinguished +
audit-gap list closed-or-deferred.

## Queue after the active program (time-consuming first, per user directive)

3. **D-288** (interp frame-stack inline+overflow redesign; ackermann 1021-deep traps at the 256 cap; ADR-likely).
4. **D-287** (validator control-stack cap 1024 rejects valid deep nesting — raise + ADR; product-envelope call).
5. Moderate: **D-284** (interp/jit/aot entry-resolution unify) · **D-290** (wabt→wasm-tools, user-directed hygiene).
6. Defer (low-signal / measure-first): **D-289 FP/param/stack large arms** · **D-286** (fill/init byte-loop).
   **D-285** (JIT byte-loop/bulk-memory codegen, ADR-0153 rework candidate — scheduled after this program).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** v0.1.0-scope program is
  thoroughly complete + 3-host green (`deb97903`); ADR-0163 bench+docs program ALL DONE. Tag/publish/cutover are
  manual, user-only — there is no release gate.
- Debt ledger: 0 `now`. Last full 3-host green = `635bd734` (Mac + ubuntu `701cbe60` + windows `OK`).
  Mac+ubuntu green through B-diag `a2ac1b89`; windows = D-279 heisenbug (non-blocking, A1-A3 exonerated).
  This turn = D-291 investigation advance (characterized + narrowed; debt+handover, no src change).

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: ✅ GREEN through B-diag `a2ac1b89` (`[run_remote_ubuntu] OK (HEAD=a2ac1b89)`). A1/A2/A3 all green
  on x86_64 Linux. `tail -3 /tmp/ubuntu.log` next resume for the latest kick.
- **windows**: ⚠️ test-all at `85157236` (A3) RED = the standing **D-279** Win64 heisenbug, NOT a regression.
  Signature: `zwasm-spec-simd` (`simd_bit_shift` — A3 NEVER touched shift codegen) + `zwasm-spec-wasm-2-0-assert`
  fail Win64-ONLY while Mac arm64 + ubuntu x86_64 are GREEN on identical source; non-deterministic (D-279 lineage
  D-180/D-245). Tracked `win64-testall segv @ a2ac1b89` (streak 0). **Commits KEPT (D7).** Cadence recorded at
  `a2ac1b89` (windows = "checked, only known heisenbug" — NOT clean-green; do not treat as green-verified).
- **Gate note (retracted alarm)**: `run_remote_windows.sh` correctly has `set -euo pipefail` + aborts before
  printing `OK` on remote failure (the wrapper exited 1 here). "windows OK" IS a real green signal; absence of
  the `OK` line + a `Build Summary: N failed` = RED. Read the Build Summary, not just the wrapper exit.

## Key refs

- **ADR-0164** (this program: `.dev/decisions/0164_trap_crash_exception_diagnostics_ux.md`). **D-292** (program
  debt row) + **D-291** (ed25519 motivating case) + **D-165** (JIT trap-code infra). ADR-0156 (no autonomous
  release). ADR-0016 (trap stderr / diagnostic phases).
- Surfaces: `src/cli/run.zig` (`surfaceTrap` interp / `surfaceJitTrap` jit+aot / `runWasmJit` / `runCwasmWasi`),
  `src/api/trap_surface.zig` (`jitTrapCode` / `trapMessageFor` / `TrapKind`), `src/cli/main.zig` (`renderFallback`
  trap path), `src/runtime/trap.zig` (Trap set), `src/engine/codegen/shared/entry.zig` (`[d-165]` print),
  `src/engine/codegen/{arm64/emit.zig,x86_64/op_control.zig}` (trap-code write sites), `src/platform/stack_limit.zig`
  (`[stack_probe]` diag). v1 per-kind msgs: `~/Documents/MyProducts/zwasm/src/cli.zig`.
