# 0103 — Adopt AddVectoredExceptionHandler + threadlocal RecoveryInfo for Win64 trap recovery

- **Status**: Accepted
- **Date**: 2026-05-22
- **Author**: Shota Kudo (via `/continue` autonomous loop, W3.a track of `.dev/phase9_13_0_close_plan.md`)
- **Tags**: phase-9, windows, win64, traphandler, spec-assert-runner, D-136

## Context

§9.13-0 Cat IV (windowsmini reconcile sweep) exit requires
`spec_assert_runner_non_simd` to run green on windowsmini —
bit-identical with Mac aarch64 + ubuntunote x86_64.

Today, the runner relies on the POSIX pair:

- `sigaction(.SEGV, .{ .handler = .{ .sigaction = sigsegvHandler } }, null)`
  installs a per-process handler that catches faults raised by
  JIT-emitted loads/stores that read or write past linear memory.
- `sigsetjmp(&jmp_buf, /*savemask=*/1)` arms a recovery point before
  the runner enters the JIT body.
- `siglongjmp(&jmp_buf, 1)` inside the SIGSEGV handler unwinds to
  the recovery point, where the runner returns `Error.Trap` to the
  assertion driver.

This pair converts hardware faults from spec-defined
`assert_trap` fixtures (`(memory.load offset oob)`, etc.) into
zwasm trap semantics. The runner sees `Error.Trap`; the spec is
satisfied.

On Win64 the POSIX surface is unavailable:

- `installSigsegvHandler` is no-op (per the design — POSIX-only).
- `sigsetjmp` / `siglongjmp` are noop stubs in zwasm v2.
- An `assert_trap` fault therefore reaches Windows' default
  handler, which terminates the process. `spec_assert_runner_
  non_simd` on windowsmini crashes mid-corpus (exit code 253);
  D-136 is the active debt row tracking this.

Survey evidence (`private/notes/p9-9.13-0-w3a-survey.md` —
gitignored):

- **Wasmtime** (`~/Documents/OSS/wasmtime/crates/wasmtime/src/
  runtime/vm/sys/windows/vectored_exceptions.rs:107-289`) uses
  `AddVectoredExceptionHandler` + threadlocal `LAST_EXCEPTION_PC`
  to convert Windows access violations into trap results.
- **Wasmer singlepass**
  (`~/Documents/OSS/wasmer/lib/vm/src/trap/traphandlers.rs:578-667`)
  uses the same `AddVectoredExceptionHandler` pattern.
- **zwasm v1** (`~/Documents/MyProducts/zwasm/src/guard.zig:230-309`)
  already implements VEH on Windows: process-wide
  `AddVectoredExceptionHandler` + threadlocal `RecoveryInfo`
  carrying `oob_exit_pc` / `jit_code_start` / `jit_code_end` /
  `active`. v1 does NOT use `__try` / `__except` blocks.

The original `.dev/phase9_13_0_close_plan.md` §W3 sketched a C
shim wrapping `__try` / `__except` (Option A) and rejected
AddVectoredExceptionHandler citing "process-wide global state
incompatible with per-runner state" (Option B). The survey shows
this rejection was based on an incomplete picture: every
productized reference (v1, Wasmtime, Wasmer) uses Option B
with **per-thread** recovery state, not "process-wide" state —
threadlocal RecoveryInfo isolates per-call recovery cleanly
even with a single shared exception handler.

Runner concurrency model (clarification for the decision below):
`spec_assert_runner_non_simd` is a sequential per-thread driver
on all three hosts. There is exactly one active JIT recovery
context per thread at any time. The runner enters JIT, arms the
recovery point, runs the JIT body, and exits with either
`Error.Trap` or success. No nested or concurrent JIT calls.

## Decision

Implement Win64 trap recovery in zwasm v2 via **process-wide
`AddVectoredExceptionHandler` + threadlocal `RecoveryInfo`**,
mirroring v1 / Wasmtime / Wasmer.

Concretely:

1. **Location**: `src/platform/windows_traphandler.zig`
   (Zone 0 platform module per `zone_deps.md`). Pure Zig,
   `@extern` declarations for the Win32 entry points.
2. **API surface** (mirrors POSIX shape, no C shim):

   ```zig
   // Zone 0 (src/platform/windows_traphandler.zig)
   pub fn install() void;       // AddVectoredExceptionHandler — once per process
   pub fn uninstall() void;     // RemoveVectoredExceptionHandler — Drop / test cleanup
   pub fn arm(info: RecoveryInfo) void;   // set threadlocal recovery state
   pub fn disarm() void;        // clear threadlocal recovery state

   pub const RecoveryInfo = struct {
       jit_code_start: usize,   // [start, end) of JIT-emitted code region
       jit_code_end: usize,
       recovery_pc: usize,      // PC to resume at (the runner's recovery label)
       recovery_sp: usize,      // SP at recovery point (Win64 ABI invariants)
       recovery_rax_trap_code: u64,  // value to load into RAX on recovery
   };
   ```
3. **Handler**: `unsafe extern "system" fn vehHandler(
   info: *EXCEPTION_POINTERS) callconv(.winapi) c_long`.
   - Filters on `EXCEPTION_ACCESS_VIOLATION` /
     `EXCEPTION_ILLEGAL_INSTRUCTION` /
     `EXCEPTION_INT_DIVIDE_BY_ZERO` /
     `EXCEPTION_INT_OVERFLOW` (mirrors Wasmtime line 181-187).
   - Reads `RIP` from `info.ContextRecord.Rip`; if
     `recovery.active and jit_code_start ≤ RIP < jit_code_end`,
     modifies `Rip / Rsp / Rax` to the recovery values and
     returns `EXCEPTION_CONTINUE_EXECUTION` (-1).
   - Else returns `EXCEPTION_CONTINUE_SEARCH` (0); fault
     propagates to Windows' default handler.
4. **Runner wiring**:
   `test/spec/spec_assert_runner_base.zig::installSigsegvHandler`
   gains a Windows arm that calls
   `platform.windows_traphandler.install()`. The existing
   `sigsetjmp` / `siglongjmp` callsites in the runner are
   replaced by `arm(RecoveryInfo{...}) → callJit → disarm()`;
   on the Windows arm, recovery is the VEH redirecting back
   into the runner.
5. **Zig-callable boundary, no C shim**: VEH callbacks are
   already `WINAPI`-callable; Zig 0.16's `callconv(.winapi)`
   + `@extern` is sufficient. No `.c` / inline-asm shim
   needed. (This is the meaningful divergence from the
   close-plan's Option A.)
6. **Mac / ubuntu paths untouched**: POSIX SIGSEGV handler
   stays. Compile-time `comptime builtin.target.os.tag` arm
   selects POSIX vs Win64 in the runner.

## Alternatives considered

### Alternative A — C shim wrapping `__try` / `__except` (close-plan's original sketch)

- **Sketch**: `src/platform/windows_seh_bridge.c` exports
  `seh_arm(*frame)` / `seh_disarm(*frame)` / `seh_recover(*frame)`
  functions; the `__try` block lives in C because Zig has no
  `__try` syntax.
- **Why rejected**:
  - Adds a new binary build dependency (`.c` source in
    `build.zig`, separate compile step). v2 has zero C source
    files today (`include/` carries wasm-c-api headers only;
    no `src/*.c`).
  - Does **not** match any productized reference. v1, Wasmtime,
    Wasmer all use VEH; none of them use `__try` / `__except`
    for JIT trap recovery. The pattern that's "more native to
    SEH" turns out to be the pattern nobody productizes.
  - `__try` / `__except` is C language syntax, not a function
    call — exposing the recovery model through a C ABI loses
    the structured-exception benefit (the recovery state has
    to be threaded through a `jmp_buf`-like struct anyway).
  - The close-plan's rejection of Option B cited "process-wide
    global state" as the disqualifier; the survey showed that
    productized references pair process-wide VEH with
    threadlocal recovery state, which is exactly the scope
    isolation the close-plan was after.

### Alternative B — Manual SEH frame walking (`RtlAddFunctionTable`)

- **Sketch**: register per-JIT-region unwind info via
  `RtlAddFunctionTable`; rely on Windows' frame-walking to
  unwind into a Zig-installed personality routine.
- **Why rejected** (consistent with close-plan): frame layout
  is undocumented in Zig 0.16; `RtlAddFunctionTable` is a
  private Windows internal (per `learn.microsoft.com/en-us/
  windows/win32/devnotes/rtladdfunctiontable`). Even when it
  works it requires per-JIT-region setup that VEH doesn't.
  No productized reference uses it.

### Alternative D — Context-stack + VEH (4th alternative surfaced by survey)

- **Sketch**: instead of a single threadlocal `RecoveryInfo`,
  maintain a per-thread stack of recovery contexts; VEH reads
  `stack.top()`. Justified if nested JIT-in-JIT calls
  become a thing.
- **Why rejected** (for THIS ADR): the runner concurrency model
  is sequential per-thread with no nested JIT. A single
  threadlocal slot is sufficient. If nested JIT calls land
  later (Phase 11+ embenchen workloads, or Phase 14
  concurrency), this ADR can be amended in place to grow the
  slot into a stack.

## Consequences

### Positive

- **D-136 closes** when the implementation chunk (W3.b per
  `phase9_13_0_close_plan.md` §6 row 7) lands and windowsmini
  `spec_assert_runner_non_simd` runs green. windowsmini reaches
  3-host bit-identical for `assert_trap` fixtures.
- **No new C source file**; v2's "pure Zig + linked C headers"
  shape is preserved. Eases the v0.1.0 RC packaging story
  (no Win64-only `.c` to bundle).
- **Matches productized references**: future readers / new
  maintainers find a familiar pattern (Wasmtime / Wasmer /
  v1). The pattern is documented in three production-grade
  references.
- **Symmetric arm/disarm API**: Win64 `windows_traphandler.arm()`
  reads like POSIX `sigsetjmp` reads. The runner's comptime
  arm becomes structural-mirror, not platform-shim.

### Negative

- **Process-wide installation order matters**: VEH is process-
  global; if zwasm-v2-as-a-library is loaded into a host that
  already installed VEH (e.g. another wasm runtime, a debugger
  helper), priority interactions need to be thought through.
  Mitigation: install with priority `0` (back of queue) so the
  host's pre-existing handlers run first; only handle faults
  whose PC falls in known JIT ranges. Test added in W3.b for
  the "host VEH wins" path. (Note: Wasmtime installs at
  priority 1; the rationale is Go-runtime compat, not a
  general best practice. Priority 0 is the safer default for
  v2.)
- **Threadlocal lifecycle**: callers MUST pair `arm` with
  `disarm` even on Error paths (the runner already does this
  via `defer` for the POSIX pair; same shape works). Audit
  hook: `audit_scaffolding §G` grep for unpaired
  `windows_traphandler.arm(` callsites.
- **Slightly more code in Zone 0**: ~80-120 LOC for
  `windows_traphandler.zig` vs ~30 LOC for a C shim's Zig
  wrapper. Acceptable for the no-`.c`-dependency win.

### Neutral / follow-ups

- **D-028 (windowsmini IPC flake re-evaluate)** — W1 partial
  result at `private/notes/p9-d028-flake-rate.md` shows the
  failure signature diverges from the original "test runner
  failed to respond" IPC framing; once the SEH bridge lands,
  corpus duration may drop (no more mid-corpus process
  termination), which could itself reduce the flake. D-028
  re-eval is queued as a follow-up after W3.b.
- **Test-only fault filtering**: the VEH handler's PC-in-
  jit-range check protects the host process from arbitrary
  JIT-region faults bypassing the recovery (e.g. a bug in
  prologue codegen). Add an edge-case fixture under
  `test/edge_cases/p9/win64_seh/` for "VEH passes non-JIT
  faults through" at W3.b time (per
  `edge_case_testing.md`).
- **W3.b chunk**: post-ADR-flip, implementation lands the
  `src/platform/windows_traphandler.zig` module + runner
  wiring + `build.zig` Windows-target glue (if needed).
  Test gate: Mac cross-compile (`-Dtarget=x86_64-windows-gnu`)
  green; ubuntu deferred per ADR-0076 D3; windowsmini
  verified at W4 reconcile.
- **W3.b-2 recovery PC/SP capture mechanism** (refined
  2026-05-22 via `private/spikes/win64-recovery-pc-sp/`):
  The `arm(RecoveryInfo)` callsites do NOT capture
  `recovery_pc` / `recovery_sp` via inline-asm local labels
  (the survey's initial Option B sketch). The spike showed
  that `lea 1f(%%rip), %[pc]` captures an address INSIDE
  the asm block, which lacks the asymmetry POSIX
  `sigsetjmp` provides (first call 0 vs longjmp-returned ≠0).
  Instead, the runner wraps the JIT call in a helper:

  ```zig
  pub fn callJitOrTrap(
      info: RecoveryInfoSetup,
      comptime jit_fn: anytype,
      args: anytype,
  ) bool {
      var rsp_on_entry: usize = undefined;
      asm volatile (
          "mov %%rsp, %[sp]"
          : [sp] "=r" (rsp_on_entry),
          :
          : .{ .memory = true }
      );
      arm(.{
          .jit_code_start = info.jit_code_start,
          .jit_code_end = info.jit_code_end,
          .recovery_pc = @returnAddress(),
          .recovery_sp = rsp_on_entry + 8,
          .recovery_rax_trap_code = 1,
      });
      defer disarm();
      @call(.never_inline, jit_fn, args);
      return false; // VEH-redirected path returns true via RAX
  }
  ```

  `@returnAddress()` gives the caller's RIP after the call;
  inline asm captures RSP; VEH sets `Rip / Rsp / Rax` on
  trap. The caller's `if (callJitOrTrap(...))` then sees
  `true` and maps to `Error.Trap`. POSIX path remains the
  existing inline `sigsetjmp` per the discipline at
  `spec_assert_runner_base.zig:2306-2312`. See spike notes
  for full rationale and disasm verification.

## References

- `.dev/debt.md` D-136 row — the structural barrier this ADR
  removes at W3.b land.
- `.dev/phase9_13_0_close_plan.md` §W3 — the close-plan's
  Option A sketch this ADR diverges from (and refreshes).
- `private/notes/p9-9.13-0-w3a-survey.md` — gitignored survey
  that surfaced the divergence (v1 + Wasmtime + Wasmer all
  use Option B; close-plan's "process-wide global state"
  rejection rationale was incomplete).
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/
  sys/windows/vectored_exceptions.rs:107-289` — productized
  VEH reference.
- `~/Documents/OSS/wasmer/lib/vm/src/trap/traphandlers.rs:578-667`
  — second productized VEH reference.
- `~/Documents/MyProducts/zwasm/src/guard.zig:230-309` — v1
  implementation of the exact pattern this ADR adopts (read,
  do not copy-paste, per `.claude/rules/no_copy_from_v1.md`).
- Microsoft docs:
  `https://learn.microsoft.com/en-us/windows/win32/api/
  errhandlingapi/nf-errhandlingapi-addvectoredexceptionhandler`
  — VEH installation reference.
- Microsoft `CONTEXT` struct:
  `https://learn.microsoft.com/en-us/windows/win32/api/winnt/
  ns-winnt-context` — register access from the handler.
- ADR-0049 — windowsmini per-chunk gate deferral; this ADR's
  W3.b impl runs the strict `test-all` only at W4 (the
  windowsmini reconcile run).
- ADR-0055 — Win64 v128 marshal precedent (Win64 ABI work in
  the same `src/platform/` / x86_64 area).
- ADR-0067 — ubuntunote pivot; same era of cross-platform
  reliability work.
- `.claude/rules/no_copy_from_v1.md` — v1 guard.zig is read,
  not copied. Re-derive the shape in v2's Zone 0 layout.
- `.claude/rules/platform_panic_vs_error.md` — when the W3.b
  implementation has `comptime builtin.target.os.tag != .windows`
  else-branches, prefer `@panic("D-NNN")` over widening shared
  `Error`.
- `.claude/rules/zone_deps.md` — Zone 0 is the correct layer
  for the `windows_traphandler.zig` module.
- `.claude/rules/libc_boundary.md` — `@extern("kernel32")`
  declarations for `AddVectoredExceptionHandler` /
  `RemoveVectoredExceptionHandler` need an ADR-0070 amendment
  classification at W3.b time (new `necessary` category
  entries since they're Win32 platform syscalls, not C
  runtime).

## Revision history

| Date       | SHA         | Change                          |
|------------|-------------|----------------------------------|
| 2026-05-22 | `<backfill>`| Status: Proposed → Accepted     |
| 2026-05-22 | `<backfill>`| Consequences refinement: W3.b-2 recovery PC/SP capture via `callJitOrTrap` helper (@returnAddress + inline-asm RSP). Validated via `private/spikes/win64-recovery-pc-sp/` Win64 cross-compile disasm. |
