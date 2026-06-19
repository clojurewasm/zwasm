# ADR-0199 — JIT `proc_exit` / trap propagation: post-call `trap_flag` check

> **Doc-state**: ACTIVE
> **Status**: Implemented (2026-06-20, @1a629c5fe) — D-468 closed. Post-call
> trap_flag check landed on both arches (arm64 CBZ-skip→epilogue via
> return_fixups; x86_64 JE-skip→emitTrapExitStub(null)). Verified: all 9 go_*
> exit rc=0 under JIT (was rc=124 hang), test-spec-wasm-2.0-assert 25539/0 on
> arm64 + x86_64-macos, zig build test green both arches.

## Context

Every non-trivial Go realworld fixture runs correctly under `--engine jit`
(byte-identical stdout to interp) but then **hangs at exit** (D-468). The
`ZWASM_DEBUG=wasi.jit` trace of `go_map_ops` is decisive:

```
total: 100 found: 34 ...          ; correct program output
proc_exit rval=0                  ; Go calls proc_exit(0) to terminate
poll_oneoff nsubs=1               ; but execution CONTINUES into the scheduler
fatal error: wasi_snapshot_preview1.poll_oneoff
proc_exit rval=2 / 4 / 5 / 5 ...  ; 11 more proc_exit calls, none terminate
```

**Root cause.** The JIT trap model is *sticky-flag + natural return*:
`proc_exit` (and the default `hostDispatchTrap`) set `rt.trap_flag = 1` and
**return normally**; the flag is only inspected by the entry shim
(`entry.zig invokeAndCheck`/`invokeAndCheckVoid`) **after the top-level JIT body
returns**. Inline traps (oob/div0) branch directly to the per-function trap stub
(immediate 1-frame unwind), but a **host-import call** has *no post-call
`trap_flag` check* (`op_call.zig` import branch: `emitImportDispatch` →
`captureCallResult` → `return`, no check). So when `proc_exit` sets the flag and
returns, the guest keeps running. For a program that *returns* to the entry
naturally (every prior realworld fixture — C/_start just returns, never calling
proc_exit) this is invisible. Go is the first guest that (a) calls `proc_exit`
expecting it to terminate and (b) does **not** return afterward — its runtime
re-enters the scheduler (`poll_oneoff`) and loops forever, so the entry shim is
never reached. `poll_oneoff` returning `notsup` (clocks.zig stub) is a *symptom*,
not the cause: even a full poll_oneoff would only turn the hang into an infinite
sleep.

**The interp does not have this bug** because it already uses a post-call check:
`proc.zig procExit` sets `host.exit_code`, and "the dispatch surface checks
`host.exit_code` after each host-call return and short-circuits," propagating up
frame-by-frame by marking each frame done (`interp/mvp.zig`).

## Decision

Mirror the interp in the JIT: **emit a post-call `trap_flag` check** that
branches to the function's trap stub when the flag is set, after **both**
(1) host-import dispatch calls and (2) body-relative `call`/`call_indirect`/
`call_ref` returns. The check propagates the unwind frame-by-frame to the entry
shim (each caller's post-call check fires in turn), exactly as interp's
frame-done propagation does. `proc_exit` then terminates immediately; this also
closes the latent class "an inline trap inside a callee, when the caller is in a
loop, must not keep looping."

Shape per arch (after `captureCallResult`, so a non-trapping result is
preserved): load `rt.trap_flag` (W17/scratch via `runtime_ptr_save_gpr` +
`trap_flag_off`), and `CBNZ`/`JNZ` to the existing trap-stub fixup target.

## Alternatives considered

- **(B) Reuse the EH FP-walk unwinder** (`zwasm_throw` `.uncaught` restores SP to
  the entry frame, zero per-call cost). Rejected for now: it conflates exit with
  exception handling, requires `proc_exit` to capture throw-site FP/glue, and is
  a larger change. It is a *perf optimization* of (A) and can supersede the
  post-call check later **iff** a call-bound benchmark shows the per-call check
  matters (measure-before-optimizing; memory `feedback_perf_measure_first`). The
  per-call check is a load+test+predictable-not-taken branch — negligible for the
  call-sparse code Wasm guests emit (guest compilers inline leaf math).
- **(C) setjmp/longjmp from proc_exit to the entry.** Rejected: pulls in a libc
  boundary (`sigsetjmp`/`siglongjmp`, ADR-0070) for what (A) does with no new
  dependency.

## Consequences

- `op_call.zig` (arm64) + `op_call.zig` (x86_64) gain a post-call check at the
  import-dispatch and body-call sites; the trap-stub fixup already exists.
- Verification MUST use the JIT assert runner `test-spec-wasm-2.0-assert` on
  BOTH arm64 AND `-Dtarget=x86_64-macos` (Rosetta) per the D-330/D-331A lesson,
  plus the existing trap corpus (no regression) + `go_*` fixtures exit rc=0 under
  `--engine jit` + the realworld diff-jit lane.
- A boundary fixture (`test/edge_cases/p<N>/proc_exit/terminates_midbody.{wat,wasm,expect}`):
  a module that calls `proc_exit(0)` then has an observable side effect which
  MUST NOT run.
- The `wasi.jit` `ZWASM_DEBUG` trace channel (added this cycle) stays as the
  permanent diagnostic primitive for this class.
