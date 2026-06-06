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

## ← LEAD: D-291 — RE-LOCALIZED to func 17 (__multi3) internal spill miscompile

**D-291 advanced this session (`136d20a5`)**: added gated caller-capture (trap_aux5/6). The "733-caller
passes a wrong result-buffer" framing is REFUTED — the gated `call 17` arg0==16777416 check NEVER fired (two
positions); last `call 17` = caller func 8, arg0=0xffc3b0 (valid stack addr). So func 17 RECEIVES a correct
result-buffer yet stores to 16777416 ⇒ corruption is INSIDE func 17. func 17 = __multi3: pushes `local.get 0`
(result ptr) at the START, runs ~40 i64 ops (spill-heavy 128-bit mul), then stores via that early-held ptr —
corrupted to __stack_pointer_init+0xC8=16777416 = a regalloc/spill miscompile of the long-lived operand. NEXT:
gated capture of func 17's RECEIVED X1 at its prologue → distinguish P1 (func-17 internal spill) vs P2 (call-tail
X1 clobber). Build `-Dtrace-stackprobe=true`; run `zwasm run --engine jit bench/runners/wasm/shootout/ed25519.wasm`;
grep `[d-291]`. Full hypothesis chain in the D-291 debt row.

**Other status**: ADR-0164 trap-diagnostics COMPLETE. **D-294 3-HOST GREEN** (`4fa16b29`/`ba111ee5`, `partial`, residuals polish).
**D-279 sha256 lead was FALSE** (corrected): zwasm computes the correct hash (interp==jit, all hosts); the
`c_sha256_hash.wasm` fixture has a wrong baked-in constant → golden-matched, never gates. ba111ee5 genuinely
SILENT (tracker fail→silent, **streak 3/5**); genuine D-279 = the `simd_bit_shift` CRASH only, H3 WITHDRAWN.
Minor: regen c_sha256_hash fixture (fold into D-290). Queued: D-288, D-284, D-290.

## Queue (time-consuming first, per user directive)

- **D-288** (interp flat/trampolined recursion OR native-stack-limit check; ADR — interp-architecture redesign).
- **D-291** (paused; see top) · **D-292 B-core** (SIGSEGV→internal-error, needs ADR-0070 amend) · C · D.
- Moderate: **D-284** (interp/jit/aot entry-resolution unify) · **D-290** (wabt→wasm-tools hygiene).
- Defer: **D-289** FP/param/stack large arms · **D-286** (fill/init byte-loop) · **D-285** (JIT bulk-memory, ADR-0153).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** v0.1.0-scope program is
  thoroughly complete + 3-host green (`deb97903`); ADR-0163 bench+docs program ALL DONE. Tag/publish/cutover are
  manual, user-only — there is no release gate.
- Debt ledger: **0 `now`** (D-294 → `partial`, 3-host green @`4fa16b29`/`ba111ee5`, residuals polish). **ADR-0164
  trap-crash-exception-diagnostics COMPLETE** (D-293 + D-292 A/B-core/C/D all done). Next: D-279 observability
  fix → D-291. Phase 16.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: ✅ **GREEN @`ba111ee5`** (`[run_remote_ubuntu] OK`) — spec_assert 25437/0, simd 13351/0, realworld
  55/0; D-294 code-13 null check confirmed on x86_64 Linux. No action.
- **windows**: ✅ genuinely **GREEN @`ba111ee5`** (`[run_remote_windows] OK`, realworld_run_runner 55/55) — D-294
  3-host green, D-279 did NOT fire. The `verify: FAIL` sha256 line is a FALSE lead (fixture has a wrong expected
  constant; zwasm's d0e8b8f… is correct — Mac-verified). Tracker = `silent` (streak 3/5). cadence `--record`ed.
- **Gate note**: `run_remote_windows.sh` `OK` line = real green; `Build Summary: N failed` (no `OK`) = RED. The
  `zig-host-hello` exit-42 + `--__selftest-crash` exit-70 "failed command" lines are EXPECTED, not crashes.

## Key refs

- **ADR-0164** (this program: `.dev/decisions/0164_trap_crash_exception_diagnostics_ux.md`). **D-292** (program
  debt row) + **D-291** (ed25519 motivating case) + **D-165** (JIT trap-code infra). ADR-0156 (no autonomous
  release). ADR-0016 (trap stderr / diagnostic phases).
- Surfaces: `src/cli/run.zig` (`surfaceTrap` interp / `surfaceJitTrap` jit+aot / `runWasmJit` / `runCwasmWasi`),
  `src/api/trap_surface.zig` (`jitTrapCode` / `trapMessageFor` / `TrapKind`), `src/cli/main.zig` (`renderFallback`
  trap path), `src/runtime/trap.zig` (Trap set), `src/engine/codegen/shared/entry.zig` (`[d-165]` print),
  `src/engine/codegen/{arm64/emit.zig,x86_64/op_control.zig}` (trap-code write sites), `src/platform/stack_limit.zig`
  (`[stack_probe]` diag). v1 per-kind msgs: `~/Documents/MyProducts/zwasm/src/cli.zig`.
