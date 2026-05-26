# EH test wrappers must install a sentinel frame — host FP-chain is unreliable

**Date**: 2026-05-28
**Tags**: EH, unwinder, inline-asm, test discipline, frame pointer,
ubuntu, Zig 0.16 self-hosted, AAPCS64, SysV, sentinel frame
**Discovered at**: HEAD `bcf46f3b` (IT-6 cycle 3c-ii follow-up),
fixed at `7d67e247`.
**Citing**: fix commit `7d67e247`; reverted Mac-green-but-ubuntu-broken
state at `bcf46f3b`.

## What happened

Cycle 3c-ii's `invokeTrampolineWith` test wrapper let the trampoline's
naked stub capture the wrapper's actual `X29` (arm64) / `RBP` (x86_64)
as `initial_fp`. The unwinder then walked the host process's frame-
pointer chain looking for a handler. Mac aarch64 was green because
AAPCS64 mandates `X29` chaining for every non-leaf call (Apple ABI
amplifies this); the walk eventually terminated at a zero-FP frame.

On ubuntu Linux x86_64 with Zig 0.16's self-hosted backend, `RBP` is
**not** reliably preserved as a frame pointer across functions. The
walk dereferenced garbage memory, corrupting some adjacent state
(likely the per-thread `@errorReturnTrace()` block or its near
neighbour). A LATER unrelated test (`engine.runner.test.runI32Export:
memory64 store+load round-trip via i64 idx_type`) crashed in stdlib
`returnError`'s `st.instruction_addresses[st.index] = @returnAddress()`
with SEGV at address `0x9` — pattern of `st = 0x1` (small invalid
pointer) deref'ing the `instruction_addresses.ptr` field at field
offset 8.

The crashing test's body was just `if (!(macos and aarch64)) return
error.SkipZigTest;` — i.e. the skip-return path was crashing because
the implicit error-trace machinery had already been broken.

## Why the diagnostic was tricky

- Mac green, only ubuntu crashes → looks like an ARCH-specific bug.
- Crash report names a test that doesn't even execute its body
  (`runI32Export` early-returns on Linux). Easy to mis-diagnose as
  a stdlib / test-runner bug.
- The corrupting test (`zwasmThrowTrampoline: uncaught path`) ran
  alphabetically EARLIER in `engine.codegen.shared.throw_trampoline`
  and exited cleanly. The corruption surfaces only at the next test
  that uses `@errorReturnTrace()`.

## Fix

Install a 2-slot sentinel `{0, 0}` and pass its address as `initial_fp`:

```zig
var sentinel: [2]usize align(16) = .{ 0, 0 };
const sentinel_ptr: usize = @intFromPtr(&sentinel);
// asm: stp x19, x29, [sp, #-16]!; mov x29, sentinel_ptr; ...; blr
// asm: pushq %rbp;             movq sentinel_ptr, %rbp;  ...; callq
```

The unwinder's `loadFrame(sentinel_ptr) → caller_fp=0` terminates the
walk at depth 1 with `.uncaught`. The test exercises the exact same
naked-stub → trampolineCore → dispatchThrow → unwind pipeline on both
arches **without depending on host stack-chain integrity**.

While at it, fixed the x86_64 invoke clobber list (R8/R9 were missing
from the SysV caller-saved set) and dropped the arm64 `X10`-as-X19-save
trick (X10 is caller-saved → vulnerable; STP/LDP on stack is correct).

## Generalisable rule (for future EH tests)

Any test that exercises code which walks a frame chain via inline asm
MUST install a sentinel `{0, 0}` and set it as the initial FP register
the walker reads. **Never** let an inline-asm test wrapper let the
walker traverse the host process's frame chain — host FP discipline
varies by ABI / compiler / optimisation level and is not a reliable
test substrate.

Specifically applies to:
- `shared/throw_trampoline.zig` — covered by this fix.
- Future EH-related test wrappers (cycle 3c-iii sp_restore + JMP).
- Any future stack-walking primitive's tests (debug ringbuffer
  frame snapshots, panic-handler thread state walkers, etc.).

## Related

- ADR-0114 D5 (FP-walk unwind algorithm; spec)
- ADR-0119 (naked-Zig trampoline design)
- AAPCS64 §6.4 (X29 chaining ABI mandate on arm64)
- SysV ABI §3.4.3 (RBP optional; not mandated as frame pointer)
- `.claude/rules/test_discipline.md` (consider §3 amendment for
  sentinel-frame discipline if the pattern recurs)
