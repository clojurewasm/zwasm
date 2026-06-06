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

- ✅ **D-287 DONE** (`cf605260`, ADR-0165): `zir.max_control_stack` 1024→4096 (deeply-nested switch.wasm now
  validates). **D-288** (queued): interp recurses NATIVELY, `frame_buf[256]` is a SEGV guard; real fix = flat/
  trampolined interp OR native-stack-limit check (ADR) — see queue.

- ✅ **D-293 DONE (slices 1–4d, substantially complete; details in debt.yaml/commits)**: per-kind JIT trap
  codegen unified arm64+x86_64 via demuxed fixup-channels — oob_table(2)/cind_sig(3)/invalid_conversion(9)/
  trunc-overflow(8)/null_reference(10)/array_oob(6)/cast_failure(11); plus slice-4a fixed the INTERP surface
  (null/cast/uncaught were mis-reported `binding_error`) + a latent arm64 call_ref→oob_table mis-report. Each
  has a runner_trap_test (JIT+interp parity). Remaining GC trampolines/i31 debt-rowed (lowest-freq, interp ok).

- ✅ **D-292 B-core DONE (ADR-0166; bundle CLOSED)** — production internal-fault handler: an internal
  SIGSEGV/crash now surfaces `zwasm: internal error … this is a bug …` + **exit 70** instead of a silent
  signal-death (distinct from a clean wasm trap = exit 1). cycle I `c395cf64` POSIX sigaction (SEGV/BUS/ILL/FPE
  → raw write + `_exit(70)`, no recovery, installed first in main.zig); cycle II `8c076db2` Windows VEH
  (`RtlAddVectoredExceptionHandler`, kernel32 per-MSDN) + a `test-internal-fault` build step
  (`zwasm --__selftest-crash`, `expectExitCode(70)`) in test-all; the gate caught a Windows bug (lost to Zig's
  own First=0 segfault VEH) → **fixed `400c7006`** (`First=1`, beats Zig's). **Exit-condition MET**:
  `test-internal-fault` exits 70 on ALL 3 hosts — windows confirmed GREEN at the `400c7006` kick
  (`[run_remote_windows] OK`, "internal error" printed + exit 70). Lesson:
  `2026-06-06-windows-custom-fault-veh-must-be-first`.

## ← LEAD: pick next — D-292 C/D (bounded, local) OR a fresh-context correctness session (D-291/D-279)

D-293 + D-292-A/B are done. Remaining ADR-0164 program: **C** (exception/EH-vs-trap distinction) + **D** (audit
zwasm trap UX vs wasmtime/wasmer/v1 → gap list) — both bounded + mostly local. Higher-value but DEEPER + needing
FRESH context (do NOT start at extreme session depth): **D-291** (ed25519 JIT large-frame address miscompile,
paused — diag infra in place; its row says "needs fresh-context session") and **D-279** (Win64 heisenbug,
non-deterministic — confirmed: it did NOT fire the `400c7006` run; §1 hypotheses incl. **H3: possible shared
root with D-291** = wide-address arith, partly Mac-testable). Correctness-first → D-291/D-279 are the priority
when fresh; D-292 C/D are the bounded fill otherwise.

## Queue (time-consuming first, per user directive)

- **D-288** (interp flat/trampolined recursion OR native-stack-limit check; ADR — interp-architecture redesign).
- **D-291** (paused; see top) · **D-292 B-core** (SIGSEGV→internal-error, needs ADR-0070 amend) · C · D.
- Moderate: **D-284** (interp/jit/aot entry-resolution unify) · **D-290** (wabt→wasm-tools hygiene).
- Defer: **D-289** FP/param/stack large arms · **D-286** (fill/init byte-loop) · **D-285** (JIT bulk-memory, ADR-0153).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** v0.1.0-scope program is
  thoroughly complete + 3-host green (`deb97903`); ADR-0163 bench+docs program ALL DONE. Tag/publish/cutover are
  manual, user-only — there is no release gate.
- Debt ledger: 0 `now`. **D-293 substantially complete** (partial) + **D-292 B-core DONE** (bundle closed —
  internal-fault handler, 3-host green incl. windows `OK @400c7006`). Last full 3-host green = `400c7006`
  (windows clean, D-279 did NOT fire). Next: D-292 C/D (bounded) or D-291/D-279 (deep, fresh-context). Phase 16
  continues, no release (ADR-0156).

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: ✅ GREEN through `6beb2630` (B-core handler + `test-internal-fault` exit-70). Whatever's kicked
  next turn — verify `/tmp/ubuntu.log` `OK`.
- **windows**: ✅ **GREEN at `400c7006`** (`[run_remote_windows] OK`) — full test-all clean (D-279 did NOT fire
  this run) + `test-internal-fault` exit-70 (First=1 VEH confirmed). D-279 update: it's **NON-deterministic**
  (silent this run; streak reset toward the §2 ≥5-silent discharge gate, now 1). My earlier "escalating
  reproducible" read was wrong — it's the classic heisenbug. Formal D-279 investigation = H3 (D-291 link, partly
  Mac-testable) when fresh.
- **Gate note**: `run_remote_windows.sh` `OK` line = real green; `Build Summary: N failed` (no `OK`) = RED.

## Key refs

- **ADR-0164** (this program: `.dev/decisions/0164_trap_crash_exception_diagnostics_ux.md`). **D-292** (program
  debt row) + **D-291** (ed25519 motivating case) + **D-165** (JIT trap-code infra). ADR-0156 (no autonomous
  release). ADR-0016 (trap stderr / diagnostic phases).
- Surfaces: `src/cli/run.zig` (`surfaceTrap` interp / `surfaceJitTrap` jit+aot / `runWasmJit` / `runCwasmWasi`),
  `src/api/trap_surface.zig` (`jitTrapCode` / `trapMessageFor` / `TrapKind`), `src/cli/main.zig` (`renderFallback`
  trap path), `src/runtime/trap.zig` (Trap set), `src/engine/codegen/shared/entry.zig` (`[d-165]` print),
  `src/engine/codegen/{arm64/emit.zig,x86_64/op_control.zig}` (trap-code write sites), `src/platform/stack_limit.zig`
  (`[stack_probe]` diag). v1 per-kind msgs: `~/Documents/MyProducts/zwasm/src/cli.zig`.
