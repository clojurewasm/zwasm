# arm64: callee-saved-homed locals MUST be spilled across JIT calls (D-291)

**Date**: 2026-06-06 · **Tags**: D-291, arm64, regalloc, homed locals, callee-saved
X20-X22, spillHomedCallerSaved, ADR-0060, ADR-0155, JIT prologue no-callee-save,
__stack_pointer corruption, ed25519, gated trap_aux diag, x86_64-was-correct,
call-crossing local, frame-base local

## The bug

`shootout/ed25519.wasm` trapped (`oob_table`) under `--engine jit` on arm64 (interp
+ wasmtime exit 0). Root cause: `homedCallerSavedSpillReload` (arm64 op_call.zig)
**SKIPPED callee-saved-bank homes** (`id >= callee_saved_slot_boundary → continue`),
assuming AAPCS64 callee-preservation of X20..X22. But per **ADR-0060** the JIT
prologue installs runtime invariants into X19..X28 WITHOUT stack-saving them, and a
JIT callee that homes a local in X20..X22 clobbers the caller's value. So a
call-crossing local homed in X20..X22 is corrupted across a call.

func 11 (21 locals, high reg pressure) homed its saved-SP `local2` in a callee-saved
reg, call-crossing; `call 14`/`call 17` clobbered it → its epilogue
`local.get 2; i32.const 480; i32.add; global.set 0` over-restored `__stack_pointer`
to garbage (0xffffffb0) → func 7 read the corrupt sp, computed a data-region result
buffer (0x10000c0) → func 17 (`__multi3`) stored the high word to 0x10000c8 = a
funcptr global → `call_indirect` loaded a wild index → `oob_table` trap.

**FIX**: spill/reload ALL register-homed locals across calls (remove the skip) —
matches x86_64's already-correct `homedSpillReload` (no skip; SysV-callee-saved
RBX/R12-R14 are also JIT-unsaved). The bug was **arm64-only**.

## Rules

1. In the JIT's ABI, NO register is preserved across a JIT-to-JIT call (the prologue
   does not stack-save the callee-saved bank — ADR-0060). So `caller-saved` vs
   `callee-saved` is irrelevant for cross-call preservation: BOTH must be spilled.
   When you see a "callee-saved → skip spill" optimization in JIT codegen, it's a
   bug unless the prologue actually saves that bank.
2. **Cross-check the two backends.** x86_64's `homedSpillReload` had no skip;
   arm64's did. When one arch's helper diverges from the other's for the "same"
   operation, the divergence is the first suspect.
3. A bug that only fires under HIGH register pressure (enough locals to spill into
   the callee-saved bank) + a long-lived call-crossing local is invisible to small
   unit tests — realworld fixtures (ed25519) are the trigger. A
   global-backed frame-base local (`__stack_pointer`) corrupted this way produces
   spectacular downstream symptoms (data-region addresses, funcptr-global clobber)
   far from the actual fault.

## Diagnostic journey (re-usable technique)

Gated (`-Dtrace-stackprobe`) `trap_aux` scratch fields in JitRuntime + targeted
captures peeled the onion: cind index (2397, garbage) → load addr (correct) → store
clobber (func 17) → `>=16MB` gate on `call 17` arg0 (highbuf_caller=7, buf=0x10000c0)
→ first-wins `global.set 0 > 0x1000000` (sp_overset_func=11) → func 11 sp_entry vs
bad_restored_sp (0xffffffb0 = -80) ⇒ local2 garbage at the epilogue ⇒ the spill skip.
Lesson: a robust `>=` range gate beats an exact-value gate (the exact `==16777416`
gate missed the real buffer 0x10000c0; only buffer+8 hit the global).
