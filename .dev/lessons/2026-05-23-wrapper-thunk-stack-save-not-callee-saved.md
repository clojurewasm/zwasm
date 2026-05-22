---
date: 2026-05-23
keywords: wrapper thunk, callee-saved, BL clobber, LR, stack-save, ADR-0106, regalloc allocatable callee-saved
citing: 7cddc6bf, 0e2d40e5
---

# Wrapper thunks: stack-save across CALL, not callee-saved registers

## The lesson

When emitting a JIT wrapper thunk that calls a JIT-emitted body
function and needs to preserve a value across the call, **save
to the stack — do NOT use a callee-saved register**, even if
the ABI says the register survives across calls.

Reason: the body's regalloc treats some ABI-callee-saved
registers as **allocatable** (per ADR-0026 + ADR-0017 +
`abi.allocatable_callee_saved_gprs`). For small functions that
don't pressure the callee-saved pool, the body may use the
register as scratch in a path the body's emit didn't pair with
a save/restore, OR the body's epilogue may write final-result
values into the register via a `MOV` shape that breaks the
callee-saved invariant from the wrapper's perspective.

Two latent bugs of this class caught via end-to-end execution
testing on 2026-05-23:

| Arch | Bug | Symptom | Fix |
|---|---|---|---|
| arm64 3-int | wrapper didn't save X30 (LR) across BL; BL writes LR; wrapper RET reads LR → infinite loop into itself | `99% CPU for 31min until kill` (`38f033b1` 3-int e2e test) | STP X30,XZR / LDP X30,XZR pair (`7cddc6bf`) |
| x86_64 SysV 2-int | wrapper used RBX (ABI-callee-saved) as results-ptr save; body's regalloc may use RBX → wrapper's RBX corrupted to body's intermediate value | `SEGV at fault address 0x77` (= result 0 value) on ubuntu (`428d6a3c` 2-int e2e test) | SUB RSP,8 / MOV [RSP],RSI / MOV RSI,[RSP] / ADD RSP,8 pair (`0e2d40e5`) |

## Why callee-saved registers fail here

Both x86_64 SysV and AAPCS64 declare RBX / X19-X28 as
"callee-saved": the callee must save them before use and
restore before return. The contract holds across normal
function call boundaries.

But for JIT-emitted bodies in zwasm v2:

- arm64: X19-X28 are project-pinned per ADR-0017 (X19 =
  runtime_ptr; X23..X28 = typeidx_base / table_size /
  funcptr_base / mem_limit / vm_base). X20..X22 are
  allocatable callee-saved per ADR-0027 — body's regalloc
  may use them with paired prologue save / epilogue restore.
- x86_64: RBX + R12..R14 are in `allocatable_callee_saved_gprs`
  per `abi.zig`. R15 = `reserved_invariant_gprs`
  (runtime_ptr).

The body's regalloc is *supposed* to pair register use with
save/restore, but the emit path's prologue/epilogue ordering
or the regalloc's accounting can have bugs that surface only
at runtime. The wrapper's safety depends on the body's
correctness here — which is a coupling we don't want.

**Stack-save eliminates the coupling**: the wrapper saves to
its own stack frame, restores after the body returns, and the
body's regalloc cannot interfere.

## When this lesson applies

- Emitting a JIT thunk that wraps a JIT-emitted body (entry
  helper, bridge thunk, trampoline, ABI converter).
- The thunk needs to preserve a register value across the
  body call (typically a pointer the body's emit didn't
  consume but the thunk needs after).
- The body's emit shares the same per-arch regalloc model as
  zwasm v2's main JIT.

If both hold → use stack-save, never callee-saved register.

## When this lesson does NOT apply

- Cross-`callconv(.c)` boundary where the body is a true
  external function (e.g. host import). The host's ABI
  callee-saved contract is reliable because the host compiler
  (clang / rustc / etc) implements it correctly.
- arm64 X30 specifically: BL **always** writes X30 regardless
  of body. The body's regalloc choice is irrelevant here —
  it's a fundamental ABI consequence of BL semantics.

## Discipline

For every new wrapper thunk emit, the per-arch reviewer
checklist:

- [ ] Lists every register the wrapper writes BEFORE the
      CALL/BL.
- [ ] For each such register, confirms either (a) the wrapper
      doesn't read it AFTER the CALL/BL, OR (b) the wrapper
      saves it to STACK across the CALL/BL.
- [ ] Has a stack-alignment proof: wrapper-entry RSP ≡ ?
      (mod 16), after stack ops, body-entry RSP ≡ ? (mod 16)
      — must match SysV (`≡ 8`) / AAPCS64 (`≡ 0`) at body
      entry.
- [ ] Has an end-to-end execution test (not just byte
      sequence assertion). Bit-pattern correctness ≠
      runtime correctness.

The byte-sequence tests verify "what bytes did the emitter
produce"; the e2e tests verify "do those bytes do the right
thing when actually executed". Both are needed; one alone is
not.

## Refs

- ADR-0106 cycle 3e Phase 2' wrappers (the family this lesson
  generalizes from).
- `src/engine/codegen/shared/wrapper_thunk.zig` — all 4
  wrapper variants (arm64 / x86_64 × 2-int / 3-int) now use
  stack-save uniformly.
- ADR-0017 (arm64 X19 invariant; allocatable callee-saved
  set).
- ADR-0026 / ADR-0027 (x86_64 + arm64 reserved-invariant +
  allocatable callee-saved sets).
- `.claude/rules/abi_callee_saved_pinning.md` — sibling rule
  for the body-side discipline (body must save/restore
  callee-saved it allocates). This lesson is the **wrapper-
  side** corollary: wrappers should not depend on that
  discipline working.
- Commits `7cddc6bf` (arm64 3-int fix) + `0e2d40e5` (x86_64
  2-int fix).
