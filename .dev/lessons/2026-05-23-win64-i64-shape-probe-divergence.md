# Win64 stack-probe fires for void recursion but not for i64 recursion

**Citing**: cycle 6 windowsmini reconcile evidence at
`1bc4baff`; spike `private/spikes/d-165-win64-fac-rec-hang/`.

## Observation

After R3 (`1e2d716d`) set `STACK_GUARD_HEADROOM = 1 MiB` on
Win64, the JIT-prologue stack-probe fires correctly for
self-recursive void functions on Win64:

- `assert_exhaustion runaway` (`()→()`) — count = 1, kind = 4.
- `assert_exhaustion mutual-runaway` — count = 1, kind = 4.
- `call_indirect runaway` — count = 1, kind = 4.
- `call_indirect mutual-runaway` — count = 1, kind = 4.

Yet for the (i64) → i64 fac-rec shape at input 1073741824,
the runner HANGS without the probe firing (no `[d-165] kind=4`
print emitted). The process is alive but stalled inside the
JIT body.

## What was ruled out (cycles 1-5)

- ~~Probe doesn't fire (frame_bytes=0)~~ — Win64 shadow space
  forces `frame_bytes ≥ 56` (`emit_setup.zig:104-111`).
- ~~stack_limit globally = 0~~ — runaway uses the same rt,
  same stack_limit; probe fires for runaway.
- ~~Byte-shape regression in emit~~ — cycle 2 + 3 unit tests
  (`emit_test_int.zig` "self-recursive (i64)→i64 probe ...")
  verify JBE patched, SUB RSP ≥ 48 on Win64, REX.W MOV r64
  post-CALL, rt-restore MOV pre-CALL — all PASS on Mac SysV
  + Win64 cross-build clean.
- ~~Host-side trap-flag check~~ — `invokeAndCheck` at
  `entry.zig:162-175` uniformly clears+checks trap_flag for
  both void and i64 paths.

## Why this is structural and not byte-level

The probe BYTES are the same for both shapes (gated on
`uses_runtime_ptr`, which both have via `call`). The
difference must be runtime: either (a) RSP doesn't actually
descend enough per i64-shape recursive call to reach
`stack_limit`, OR (b) the probe fires but the trap stub
itself or the unwind hangs on the i64-shape's caller
continuation (i64.mul of spilled local × RAX).

## Why this is hard to discriminate

Native Win64 hangs are not observable from this loop's
autonomous toolchain:

- `scripts/run_remote_windows.sh test-all` hangs at fac-rec
  → can't complete to surface log.
- The runner buffers stdout/stderr; the W4 DIR beacon for
  `fac : assert_exhaustion fac-rec i64:1073741824` doesn't
  appear in the log (cycle 6 evidence stops at fac-ssa).
- The cycle-4 `INC [R15+232]` writes to JitRuntime memory
  but the host can't read it during the hang.
- No external lldb / Windbg attach automation exists in
  scripts/ today.

## Discrimination paths left

| Path | Cost | Confidence |
|---|---|---|
| Custom small-input edge-case fixture (assert_exhaustion fac-rec i64:10000) wired into spec_assert_runner | medium (~1 day; wast lexer + runner update) | high — tests input-dependence |
| windowsmini lldb-attach session via SSH | high (interactive; not autonomous-friendly) | very high |
| Cross-compile + dump JIT bytes via DEBUG path | medium (~1 day; needs new build flag + dump helper) | medium |

## Related

- D-165 debt row (filed 2026-05-23 by this cycle).
- ADR-0105 D2/D3 (stack-probe wiring; runaway works, fac-rec
  doesn't).
- Lesson `2026-05-23-win64-stack-probe-headroom.md` (R3 fix
  rationale).
- Lesson `2026-05-22-win64-stack-probe-headroom.md` (R3 cycle
  6 root-cause).
