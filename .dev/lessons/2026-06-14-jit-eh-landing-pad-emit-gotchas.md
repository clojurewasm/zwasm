# JIT EH landing-pad / emit-synthesized-call gotchas (D-327 / D-328)

**2026-06-14** — from the JIT exnref completeness work (catch_ref/catch_all_ref
reify + throw_ref round-trip). Five traps, all cost ≥1 cycle each.

## 1. Catch-target block result vregs need LOCKSTEP minting (liveness + emit)

A try_table catch lands at a block whose results arrive via the unwinder, NOT a
ZIR op. The liveness pass and the arm64/x86_64 emit pass walk the ZIR in LOCKSTEP
minting one vreg per value-producing op (`emit's next_vreg stays in lockstep with
liveness`, emit.zig); `alloc.slots` is sized from liveness. So a multi-value catch
result (`(block (result i32 exnref))`) gets NO vregs minted → both default to vreg
0 → collide to one slot. **Emit-only fresh-vreg allocation FAILS** (desyncs from
liveness → wrong slots → corrupts UNRELATED single-param catch tests). Fix (D-328):
mint `result_arity` distinct vregs at the catch-target block's `.end` in BOTH
passes identically — `liveness.zig` + `emit.zig` ×2 — truncating dead body vregs to
the block entry first, then minting. The `.end` op carries block_idx in its
payload; `BlockInfo.is_catch_target` (set by lower.zig) flags which blocks.

## 2. try_table is TRANSPARENT for its OWN catch labels

`(try_table (catch $e $h))`: the catch `label_idx` resolves in the context OUTSIDE
the try_table — `label_idx 0` = the ENCLOSING block, not the try_table itself. When
resolving the target block from the lowerer's block_stack (with the try_table
already pushed), skip it: `block_stack[len - 2 - label_idx]` (the `-2` = -1 0-based,
-1 for the try_table at top). Also: only `.block`-kind targets need result-vreg
minting (a loop branches to its START, never its `.end`).

## 3. Dead code leaves vregs on the operand stack — depth ≠ "fall-through dead"

After a `throw`/`unreachable` the body is dead but the emit/liveness operand stack
is NOT truncated to entry depth (the dead `i32.const`s linger). So "is the
fall-through dead?" detected by `stack_len == entry_depth` is WRONG. Robust:
truncate the operand stack to the block's `entry_depth`, THEN mint the canonical
result vregs (the catch delivers them; the lingering dead vregs are discarded).

## 4. Emit-synthesized CALLs clobber caller-saved regs the regalloc can't model

The reify call (`BLR reify_exnref_fn`) is emit-synthesized — the regalloc/liveness
never saw it, so it doesn't spill caller-saved vregs across it. Any value written
to a caller-saved reg BEFORE the call is LOST. Fix: emit the reify call FIRST, then
write the params (after the only call → they survive). Symptom of getting it wrong:
the i32 result reads 0 / garbage while a round-trip that routes the value through
the Exception payload still passes (masking the bug).

## 5. Emit-synth C-ABI calls to REGULAR Zig fns need Win64 shadow space

`reifyExnref`/`rethrowFromExnref` are regular `callconv(.c)` fns → on Win64 they
HOME their register args to the caller's 32-byte shadow space. An emit-synth call
in a function with no IR calls (`outgoing_max_bytes == 0`) has no reserved shadow →
Win64 stack corruption. Wrap with `op_call.emitShadowAlloc/Free(outgoing_max_bytes)`
(no-op on SysV / when the frame already reserves outgoing space). The existing
throw-trampoline call did NOT expose this — its callee is `callconv(.naked)` and
never touches the home space. Latent (the windows spec runner doesn't execute
catch_ref) but real for runtime catch_ref on Win64.
