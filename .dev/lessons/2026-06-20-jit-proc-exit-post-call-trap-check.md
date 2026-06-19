# JIT trap_flag must be checked at the call site, not just the entry shim (D-468)

> **STATUS: FIXED @1a629c5fe (ADR-0199), both arches.**

**Symptom.** Every non-trivial Go realworld fixture printed byte-identical-to-
interp correct output under `--engine jit` then HUNG at exit (rc=124). `go_hello`
"prints" but never exits; `go_map_ops` printed its line then `fatal error:
wasi_snapshot_preview1.poll_oneoff` → panic-during-panic livelock.

**Root cause.** The JIT trap model was *sticky-flag + natural return*: `proc_exit`
(and the default `hostDispatchTrap`) set `rt.trap_flag = 1` and **return
normally**; the flag was only inspected by the entry shim AFTER the JIT body
returned. Host-import call sites had **no post-call trap_flag check**. Inline
traps (oob/div0) branch to the per-function trap stub immediately, so they were
fine; host calls were not. Every realworld guest before Go *returned* to the
entry naturally (C/_start returns; it never calls proc_exit), so the gap was
invisible. Go calls `proc_exit` deep in its runtime and does **not** return — it
re-enters the scheduler (`poll_oneoff`) and loops, so the entry shim is never
reached. `poll_oneoff` returning `notsup` was a *symptom*, not the cause.

**Fix.** Mirror the interp ("check `host.exit_code`/trap after each host-call
return + short-circuit", proc.zig/mvp.zig): emit a post-call `trap_flag` check
after EVERY call (call/call_indirect/call_ref, both arches) that unwinds to the
function epilogue at the call site. Must branch to the **clean epilogue** (arm64
`return_fixups`; x86_64 `emitTrapExitStub(null)`), NOT a kind-setting trap stub,
so the host-set `trap_flag`/`trap_kind`/`exit_code` survive (proc_exit must still
surface "program-requested exit"). `return_call` is a terminator (immediate RET)
→ the caller's check catches it; no gap.

**Method lessons.**
1. **Trace, don't hypothesise.** A `ZWASM_DEBUG=wasi.jit` channel (added to the
   JIT WASI thunks) showed `proc_exit rval=0` followed by `poll_oneoff` —
   instantly settling "proc_exit is reached but execution continues" (hyp-2) and
   refuting the poll_oneoff-stub theory (hyp-1). One trace beat three hypotheses.
2. **A bug masked by "natural return" needs an observable that differs.** The
   edge-case runner only checks trap-vs-value (not the trap *kind*), and proc_exit
   always trips the sticky flag at entry → it could not express this test. The
   RED unit test puts an `unreachable` AFTER a trap-flagging call (nested, to
   force both the import-call and body-call checks): correct keeps `trap_kind !=
   unreachable_(5)`; the bug ran the `unreachable` (==5).
3. **Verify JIT codegen on both arches** with `test-spec-wasm-2.0-assert` (the
   JIT runner) — arm64 AND `-Dtarget=x86_64-macos` (D-330/D-331A lesson).

See [[2026-06-20-elusive-jit-miscompile-techniques]], [[D-468]], ADR-0199.
