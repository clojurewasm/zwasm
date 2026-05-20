# 0034 — JIT-execution sentinel (per-prologue flag store)

- **Status**: Accepted (partial — see D-055; ARM64 inject landed, x86_64 deferred)
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8a / 8a.2-a autonomous /continue cycle
- **Tags**: roadmap, phase8, diagnostic, jit, observability, prologue, abi

## Context

ROADMAP §9.8a / 8a.2 calls for a **JIT-execution sentinel**: an
always-on signal that distinguishes "JIT compiled successfully
AND a JIT-emitted body actually executed" from "JIT compiled
successfully but never invoked". The row text ascribes this to
"the v1-era recurring 'is the JIT actually running' confusion"
— a real failure mode v2 has only partially eliminated.

Current v2 state on this question:

- `realworld_run_jit` runner classifies post-`compileWasm`
  outcomes as `COMPILE-PASS` (compile-only mode) /
  `RUN-PASS` / `RUN-TRAP` / `RUN-NO-ENTRY` /
  `RUN-UNSUPPORTED-SIG` / `RUN-TIMEOUT` based on exit
  semantics. `RUN-NO-ENTRY` and `RUN-UNSUPPORTED-SIG` already
  catch "compiled but no entrypoint to invoke", but
  **`RUN-TRAP` does not differentiate "JIT body ran then
  trapped" from "trap fired before JIT body even started"**
  (e.g. WASI host stub fired immediately on entry, never
  reaching JIT-emitted bytes).

- D-054's `as-loop-broke` failure (OrbStack-only,
  introduced post-`4d6fc0b` 8.4-d hoist cap=4 integration)
  is exactly the class of bug where "did JIT body actually
  run?" matters for diagnosis. 8a.1's pass_diagnostics
  surfaces *which compile passes ran*; 8a.2's sentinel
  surfaces *did the emitted code actually execute*. The two
  signals together localise the failure.

- The 8a.5 cap-removal investigation needs both signals.
  8a.1 closed at `af0fb5a`; 8a.2 (this ADR) is the next
  prerequisite.

The row text fixes a budget: "Delta on prologue size is at
most 4-8 bytes (ARM64 single LDR-ADD-STR or x86_64 single
INC-MEM); negligible for hot-loop benchmarks." Operationally,
the sentinel must be cheap enough to leave on by default — no
build-flag gate per ROADMAP §A12 (release-build observability
should be free or near-free, not require a separate
diagnostic build).

## Decision

**Add a `jit_executed_flag: u32` field to `JitRuntime` (in
`src/engine/codegen/shared/jit_abi.zig`); both arches' JIT
prologue stores the constant `1` into it after the
ABI-pinned FP/LR save and runtime-ptr load complete.** Always
on; no build-flag gate.

### Concrete shape

#### `JitRuntime` extension

```zig
pub const JitRuntime = extern struct {
    // ... existing fields (vm_base, mem_limit, funcptr_base,
    //     table_size, typeidx_base, trap_flag, globals_base,
    //     globals_count, host_dispatch_base, host_dispatch_count) ...

    /// §9.8a / 8a.2 (ADR-0034) — per-prologue sentinel store.
    /// JIT-emitted prologue writes `1` here unconditionally.
    /// Caller pre-clears to `0` before each guest invocation;
    /// post-call read of `0` proves the JIT body never executed
    /// (despite compile success); read of non-zero proves at
    /// least one JIT-emitted prologue ran. Always-on; no
    /// build-flag gate.
    jit_executed_flag: u32 = 0,
};
```

Field placement at struct end keeps existing `<field>_off`
offset constants stable. New offset constant
`jit_executed_flag_off: u12` follows the existing 4-aligned
imm12 budget pattern.

#### ARM64 prologue inject

Per ADR-0021's prologue layout (current 32 bytes / 36 with
frame), insert **2 instructions (8 bytes)** between the
existing X19 = X0 setup (word 7) and the optional `SUB SP`:

```asm
ORR W17, WZR, #1                    ; W17 = 1 (4 bytes)
STR W17, [X19, #jit_executed_flag_off]  ; *(rt + off) = 1 (4 bytes)
```

Total prologue: **40 bytes (no frame) or 44 bytes (frame > 0)**.
W-form STR with 4-aligned imm12 offset; the existing
prologue.zig compile-time check
(`if ((trap_flag_off & 3) != 0) @compileError`) extends to
`jit_executed_flag_off`. Choice of W17: a caller-saved
scratch outside the existing X19 (runtime ptr) / X20-X28
(callee-saved) reservation, never used by the body's first
instruction. Per Arm IHI 0055 §6.4 W17 is IP1 (intra-
procedure call scratch), free to clobber.

#### x86_64 prologue inject

Existing x86_64 prologue (per `src/engine/codegen/x86_64/
emit.zig`'s emit_prologue routine) terminates with `MOV R15,
RDI` (runtime ptr setup) and an optional `SUB RSP, frame`.
Insert **1 instruction (7 bytes)** after R15 is loaded:

```asm
MOV DWORD PTR [R15 + jit_executed_flag_off], 1   ; 7 bytes
```

Encoded as `41 C7 87 [imm32] 01 00 00 00` (REX.B + C7 /0
ModR/M with R15 base + disp32 immediate). disp32 form is
forced to keep the encoding canonical regardless of
`jit_executed_flag_off` magnitude.

Total cost: **7 bytes per JIT function prologue** on x86_64,
**8 bytes on ARM64**. Within row text budget.

### Same-process consumer

Unit tests (and any future in-process diagnostic tools):

```zig
var rt: JitRuntime = .{ .jit_executed_flag = 0, /* … */ };
const result = try entry.callI32NoArgs(module, 0, &rt);
try testing.expect(rt.jit_executed_flag != 0);
```

The flag is reset by the caller before each invocation; the
prologue stores 1 unconditionally. Concurrent invocation
across threads is out of scope for v2 (Phase 14 concurrency
re-architecture revisits per-thread storage; until then,
JitRuntime is single-threaded).

### Cross-process consumer (realworld_run_jit)

`realworld_run_jit` invokes JIT inside a forked child with a
SIGALRM deadline. The child cannot directly hand the flag
back across fork boundary; instead it **prints a marker line
to stderr** before exit:

```
[jit-exec-flag] 1
```

…or `0` if the JIT body was never invoked despite compile
success. The parent's `runFixtureWithTimeout` captures the
child's stderr (already collected for trap diagnosis) and
greps for this marker line; the resulting bool feeds a new
`run_jit_verified` / `run_jit_compile_only_path` distinction
in the runner's tally.

This piece (8a.2-d sub-row) builds on the prologue inject
(8a.2-b/c); the prologue change is independently useful for
unit-test consumers and the future spec_assert path.

### What this ADR does NOT do

- **No build-flag gate** — sentinel is always on. Per ROADMAP
  §A12 the cost (8/7 bytes per prologue) is negligible vs.
  the alternative of conditional codegen complexity.
- **No counter** — flag (boolean store) suffices for the
  named "did JIT run" question. The 8a.1 `pass_diagnostics
  .applied` already counts compile-time pass invocations;
  a runtime invocation count would duplicate ringbuffer
  Category.exec (M3-c deferred per ADR-0028).
- **No interaction with trap path** — the prologue inject
  fires unconditionally on entry; later traps inside the
  body don't unset the flag. This matches the question's
  intent: "did *any* JIT body byte execute?".
- **No realworld_run_jit cross-process integration** — that
  is 8a.2-d's separate sub-row.

## Alternatives considered

### Alternative A — `jit_executed_count: u32` (counter)

- **Sketch**: same field name, but the prologue does
  LDR-ADD-STR (ARM64) / INC DWORD PTR (x86_64) instead of
  store-of-1. Tracks total invocations.
- **Why rejected**:
  1. **Information overlap with 8a.1**: 8a.1's
     `pass_diagnostics[emit].applied` already records "how
     many ZirInstrs emitted per func" at compile time; the
     8a.2 counter would record "how many invocations" at
     runtime. Different axes, but the second axis is M3-c
     scope (per-ZIR-instr / per-call exec category in
     ADR-0028) — out of scope for §9.8a.
  2. **ARM64 cost**: LDR-ADD-STR is 12 bytes vs flag's 8
     bytes. Both within row budget but the simpler form
     wins on Occam.
  3. **Race-free** under single-thread JIT: flag stays
     correct; counter would need `LDADDAL` on ARMv8.1+ for
     atomicity (we don't enforce ARMv8.1+).
  4. **Sentinel role suffices**: the named confusion is
     "did JIT run at all?" — yes/no. Counter is overkill.

### Alternative B — Build-flag gate (`-Dtrace-ringbuffer` reuse)

- **Sketch**: gate the prologue inject behind
  `comptime trace.enabled`. Default-off in release.
- **Why rejected**:
  1. **Operational use case**: D-054 / future regression
     diagnosis on shipped builds would need the sentinel
     present; gating defeats the "always answers the
     question" property.
  2. **8 bytes is below noise**: per-func prologue cost is
     amortised across all body instructions. tinygo_fib's
     ~thousand recursive calls add ~8 KB extra emitted
     bytes; bench impact undetectable.
  3. **Different intent than ADR-0033**: trace ringbuffer
     is observational logging (variable cost per event;
     potentially high-frequency); sentinel is a structural
     bit (one-shot per call). Different cost classes →
     different gating policy.

### Alternative C — Diagnostic ringbuffer Category.exec entry

- **Sketch**: prologue calls `trace.writeExec(func_idx)`;
  exec category from ADR-0028 surfaces.
- **Why rejected**:
  1. **C-ABI call from prologue is heavy**: would require
     spilling caller-saved regs around the helper; turns 8
     bytes into ~30+ bytes per func.
  2. **Mid-prologue C-ABI call breaks the runtime-ptr
     handoff**: X19 / R15 setup must complete before any
     non-prologue code runs.
  3. **ADR-0028 declares exec category as M3-c (deferred
     to Phase 8+)**: the immediate need is the structural
     bit, not full per-call instrumentation.

### Alternative D — Trap-stub-side sentinel

- **Sketch**: the trap stub sets a different flag bit;
  combined with the prologue flag, the runner can
  distinguish (i) JIT ran cleanly (ii) JIT ran then trapped
  (iii) trap fired before JIT body.
- **Why rejected** (deferred):
  1. Useful but additive — case (iii) is 0% / 100% answered
     by this ADR's flag. Cases (i) vs (ii) are already
     answered by RUN-PASS vs RUN-TRAP exit semantics.
  2. Adds trap-stub complexity at the same time as 8a.5's
     cap-removal investigation depends on a stable trap
     stub. Defer.

## Consequences

### Positive

- **D-054 diagnosis acquires a Linux-x86_64-vs-windowsmini-
  x86_64 differential**: the OrbStack-only `as-loop-broke`
  FAIL can be probed with "did the JIT prologue fire on
  OrbStack at all?" via the sentinel. If the flag stays 0
  on OrbStack but flips to 1 on windowsmini for the same
  fixture, the regression localises to the JIT-entry path
  (Rosetta-emulation interaction); if both flip to 1, the
  bug is in body emit. Either answer is a meaningful
  bisect.
- **Always-on, zero build-mode cognitive load**: shipped
  builds emit and exhibit the sentinel; no
  `-Dtrace-ringbuffer=true` re-build needed for the v1-
  confusion-killing question.
- **Negligible bench impact**: 8/7 bytes per prologue,
  fired at most once per JIT call entry; not in the inner
  loop's body. tinygo_fib (highest call rate)
  hyperfine-measurable difference is below noise floor.
- **Compositional with 8a.1**: pass_diagnostics tells which
  compile passes fired; the sentinel tells whether any
  emit actually executed. The pair localise compile-vs-
  exec failure modes.

### Negative

- **JitRuntime grows by 4 bytes** (u32 field), pushing
  total `head_size` from 40 → 44 bytes. Still single-cache-
  line on 64-byte-line machines; existing imm12 budget
  asserts in `jit_abi.zig` cover the new offset.
- **Caller responsibility**: every JitRuntime construction
  must zero-initialise `jit_executed_flag` (Zig's `= 0`
  default + `extern struct` non-default-init issue —
  callers using `var rt: JitRuntime = .{...}` syntax must
  include the field explicitly OR rely on `= 0` default
  taking effect). Documented in the field comment.
- **Cross-process surface (8a.2-d) requires runner work**:
  realworld_run_jit's child-prints-marker-to-stderr scheme
  is mechanical but adds a parser code path. Bounded
  scope; sub-row sized.
- **Field can be subverted by host code that writes 1
  before the JIT call** — e.g. a buggy test that forgets
  to clear. Documentation discipline; not a structural
  hazard.

### Neutral / follow-ups

- **8a.2-b**: Add `jit_executed_flag: u32 = 0` field +
  `jit_executed_flag_off` offset constant + ARM64 prologue
  inject (2 insns) + unit test asserting flag flips post-
  call.
- **8a.2-c**: x86_64 prologue inject (1 insn) + parallel
  unit test.
- **8a.2-d**: realworld_run_jit child marker print +
  parent stderr grep + new RUN-JIT-VERIFIED /
  RUN-JIT-COMPILE-ONLY-PATH classification.
- **8a.2-e**: 3-host gate; close 8a.2 [x].
- **D-054 cross-host investigation**: with 8a.2 landed,
  re-run OrbStack `as-loop-broke` fixture; record sentinel
  flag in commit body. Becomes a 8a.5 work artefact.
- **8a.4 (ZWASM_DIAG)**: the sentinel does NOT need
  runtime opt-in; 8a.4 surfaces 8a.1 pass-trace + 8a.3
  bench-delta only.
- **Phase 14 concurrency**: `JitRuntime` is per-call-site;
  multi-threaded guests will need per-thread JitRuntime
  instances anyway, at which point the flag stays
  per-instance. No multi-thread coordination needed.

## References

- ROADMAP §9.8a / 8a.2 (JIT-execution sentinel), §A12 (no
  pervasive build-time `if`), §11 (zone layering)
- ADR-0017 (JitRuntime ABI; this ADR adds one field)
- ADR-0021 (ARM64 prologue.zig single-source-of-truth;
  prologue extension lands here)
- ADR-0026 (x86_64 invariant strategy; prologue inject
  coordinates here)
- ADR-0028 (Diagnostic M3 trace ringbuffer; sentinel is
  the structural bit complement to ringbuffer's
  observational events)
- ADR-0033 (per-pass diagnostic extension; 8a.1's
  compile-pass twin to 8a.2's exec sentinel)
- D-054 (OrbStack-only as-loop-broke regression; primary
  near-term consumer of this signal)
- `src/engine/codegen/shared/jit_abi.zig` (JitRuntime
  layout)
- `src/engine/codegen/arm64/prologue.zig` (ARM64 prologue
  body_start_offset helper)
- `src/engine/codegen/arm64/emit.zig` (ARM64 emit_prologue
  call site for the inject)
- `src/engine/codegen/x86_64/emit.zig` (x86_64 prologue
  emit; D-052 prologue extraction deferred — emit.zig
  inline edit for now)
- `test/realworld/run_runner_jit.zig` (8a.2-d cross-
  process surface target)
- Arm IHI 0055 §6.4 (AAPCS64; W17 = IP1 caller-saved
  scratch)
- Intel SDM Vol 2 (MOV mem32, imm32 = C7 /0 encoding)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `5a6e42d8` | Initial accepted version (§9.8a / 8a.2-a design framing) |
| 2026-05-09 | `<backfill>` | **Refinement (§9.8a / 8a.2-d)**: cross-process surface uses **exit-code encoding** (5 = pass+compile-only-path, 0 = pass+verified) instead of the originally-spec'd stderr marker line. Functionally equivalent: both convey the same single bit (flag != 0 vs flag == 0) on the success path. Exit-code form avoids fork-time pipe / dup2 setup, fitting the runner's existing exit-code → RunResult decoding pattern. The two new RunResult variants (`pass_verified`, `pass_compile_only_path`) replace the prior unified `pass`. Stderr marker remains a viable future option if multi-bit / multi-event surface is needed (e.g. trap-stub side flag in M3-c). |
| 2026-05-11 | `3d0e8a7c` | Status flipped to `Accepted (partial — see D-055; ARM64 inject landed, x86_64 deferred)` per the 2026-05-11 ADR audit (`private/20250511_adr_audit/SUMMARY.md` §3.4 / batch_C). The ARM64 prologue inject (8a.2-b) landed at `260bd27`; the x86_64 prologue inject (8a.2-c) is **structurally blocked** on D-055 (`x86_64/prologue.zig` extract from D-052 + emit_test migration to body_start_offset()-relative pattern). On Mac aarch64 the sentinel works as designed; on OrbStack Ubuntu and windowsmini x86_64 hosts `jit_executed_flag` reads 0 post-call regardless of actual JIT execution. The §"Positive / D-054 differential" claim is therefore conditional on D-055 discharging. ADR-0050 D-1's `Accepted (partial — see D-NNN)` notation matches this state. |
