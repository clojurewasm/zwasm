# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## D-291 — PAUSED for fresh context (standing investigation; full detail in the D-291 debt row)

ed25519 JIT `oob_table` miscompile, EXHAUSTIVELY localized this session (commits `6e49ecad`→`af2e1f18`,
gated `-Dtrace-stackprobe` diagnostics `trap_aux..trap_aux4`): func 17 (a 128-bit multiply) clobbers
`memory[16777416]` because it is called with `local0 ≈ 16777416` — a WRONG result-buffer ptr that one of its
733 callers computes ~16MB TOO HIGH (the addr lands in the DATA region, where a stack temp never should).
Frame/spill helpers + data-seg + load + cind all RULED OUT. NEXT (fresh session): runtime-capture the func-17
caller's result-buffer / SP computation (return-address → which caller → its WAT) → confirm __stack_pointer-
global vs wide-i32-arith miscompile. Non-gating (ed25519 excluded from suite/bench). **Paused at turn ~14 of a
long session per the debt row's "focused fresh-context session" guidance** — the diag infra makes resume cheap.

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

- ✅ **D-287 DONE** (`cf605260`, ADR-0165): `zir.max_control_stack` 1024→4096 (deeply-nested switch.wasm depth
  2568 now validates; validator `control_buf` ~280KB safe). Forward-ref: heap control_buf to drop the cap.
- **D-288 investigated, fix REVERTED** (queued): interp recurses NATIVELY (mvp.zig:654 invoke←callOp), `frame_buf
  [256]` is a SEGV guard; real fix = flat/trampolined interp OR native-stack-limit check (ADR). See queue.

- ✅ **D-293 slices 1–3 DONE** (3-host green through `631e52f6`): per-kind JIT trap codegen via demuxed
  fixup-channels, UNIFIED arm64+x86_64 — slice-1 `15a54fdf` oob_table (code 2; table-access + cind bounds),
  slice-2 `24a405eb` indirect_call_mismatch (code 3; cind/tail sig), slice-3 `0892ee36` trapping-trunc (NaN→9
  invalid_conversion + range→8 int_overflow). Each has a runner_trap_test asserting the precise code.

- ✅ **D-293 slices 4a–4d DONE** — slice-4a `ebb87e33` completed the trap SURFACE (added `null_reference`/
  `cast_failure`/`uncaught_exception` to `TrapKind`+`mapInterpTrap`+messages — they were in `runtime.Trap` but
  the INTERP mis-reported them as `binding_error`; an interp-parity fix); 4b `2b1fa81f` JIT null_reference (10)
  for call_ref-null + ref.as_non_null (+ fixed a latent arm64 call_ref→oob_table mis-report); 4c `8980bebe`
  struct/array null→10 + array index OOB→oob_memory(6); 4d `0d13e635` ref.cast/ref.cast_null mismatch→
  cast_failure(11). Each has a runner_trap_test (JIT+interp parity). **D-293 JIT trap precision SUBSTANTIALLY
  COMPLETE** — remaining (array.len/fill/copy/init/new trampolines + i31) is lowest-freq GC-JIT w/ ambiguous
  trampoline failure semantics; debt-rowed, NOT worth grinding (interp already precise for all of them).

## ← LEAD: D-292 B-core — internal SIGSEGV/@panic → graceful INTERNAL ERROR (investigation-first)

Pivot from D-293 (trap-KIND precision, done) to D-292 B-core (crash-vs-trap DISTINCTION). Step-0 finding (from
the ADR-0164 program): NO signal handling anywhere (`grep` cli/+entry = empty) → an internal fault (a v2 codegen
bug) hits the OS as raw signal 11 / exit 139, **indistinguishable from a clean wasm `Trap`**. v2 uses NO
signal-based wasm semantics (all traps are explicit checks), so ANY such signal = an internal bug → should
surface a DISTINCT "internal error", not masquerade as a wasm trap. NEXT (investigation-first, this is
architectural): (1) confirm the gap (a deliberately-faulting fixture → observe exit 139 w/ no distinction);
(2) design = a `sigaction`/vectored-exception handler → needs an **ADR-0070 amendment** (new libc symbol
`sigaction`, per `libc_boundary.md`) + a design ADR; (3) then TDD. Do NOT rush to code — file the ADR(s) first.

## Queue (time-consuming first, per user directive)

- **D-288** (interp flat/trampolined recursion OR native-stack-limit check; ADR — interp-architecture redesign).
- **D-291** (paused; see top) · **D-292 B-core** (SIGSEGV→internal-error, needs ADR-0070 amend) · C · D.
- Moderate: **D-284** (interp/jit/aot entry-resolution unify) · **D-290** (wabt→wasm-tools hygiene).
- Defer: **D-289** FP/param/stack large arms · **D-286** (fill/init byte-loop) · **D-285** (JIT bulk-memory, ADR-0153).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** v0.1.0-scope program is
  thoroughly complete + 3-host green (`deb97903`); ADR-0163 bench+docs program ALL DONE. Tag/publish/cutover are
  manual, user-only — there is no release gate.
- Debt ledger: 0 `now`. slice-4c `8980bebe`: **ubuntu GREEN** (`OK f4877ec4`). slice-4d `0d13e635`: Mac green;
  ubuntu kicked this turn. slice-4b windows was D-279 heisenbug (recorded, kept). D-291 diag gated.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: ✅ GREEN at slice-4c `f4877ec4` (`[run_remote_ubuntu] OK`) — GC struct/array routing confirmed.
  slice-4d `0d13e635` kicked this turn — verify `/tmp/ubuntu.log` `OK` next resume.
- **windows**: slice-4d touched only GC op handlers (`ref_cast*`) — NOT an ABI-touching path; windows cadence
  likely deferred (verify `should_gate_windows.sh`). If kicked, a `spec-simd`/`wasm-2-0-assert` Win64-only fail
  w/ ubuntu+Mac green = **D-279 heisenbug** (record + keep, D7). Last windows-recorded = `877be5cf`.
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
