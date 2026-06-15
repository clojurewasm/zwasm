# Block-result merge vregs need liveness extension to the block end

**Context**: D-330 c_sha256 dropped the final `\n` under JIT (106 vs
107 bytes). After 4 mis-localizations (func-11 / func-8 / func-4
block-merge / cross-call-X22-clobber — all DISPROVEN by runtime
traces), an instrumented regalloc probe found the true root.

## The bug

A `block (result T)` whose result is delivered by a `br`/`br_if`
(captured at emit time by `captureOrEmitBlockMergeMov` into a physical
register) had **no matching liveness extension**. liveness.zig killed
the carried merge vreg at the `br` pc (or at a fall-through `drop`),
so its live range ended mid-block. regalloc then freed its slot and an
intra-block temp (in c_sha256: the inlined-strlen SWAR loop's
`i32.add`) **reused the same slot**, clobbering the merge value. At the
block `.end` the merge read garbage → strlen off by one → fputs wrote
len-1 → the `\n` was dropped.

## The fix (`960a27b4`, liveness-only, arch-independent)

The `if`-frame merge machinery already handled this (D-093 d-11/d-12):
capture the merge vregs at `.else`, re-inject at `.end` (bump last_use
+ swap sim_stack so post-block consumers extend the canonical vreg).
**Plain `block`+`br` had the identical requirement but was never
wired.** Fix: capture `br`/`br_if`-carried result vregs into the target
block/try_table frame's `merge_vregs`, and fire the `.end`
re-injection for block frames too. New `Frame.is_loop` excludes loop
targets (a `br` to a loop carries PARAMS on the back-edge, not results).

## Rules

1. **emit-time merge capture MUST have a liveness twin.** Any place
   the per-arch emit captures a vreg's *register* as a merge target
   and assumes it survives to a later merge point, the liveness pass
   must extend that vreg's range to the same point — else regalloc
   reuses its slot and the merge reads garbage. (Same class as D-093
   d-11/d-12 for if-frames; D-147 parallel-move for cycles.)
2. A JIT *value* miscompile with clean liveness/regalloc *invariants*
   can still be a liveness *range under-computation* — instrument the
   actual def_pc/last_use_pc/slot, don't reason from the invariant
   checks alone (those passed here).
3. `br_table` (multi-target, payload = label count) has the same
   latent gap, deferred as D-333.

**Citing**: `960a27b4` (fix + RED→GREEN liveness unit test); D-333
(br_table follow-up); supersedes the cross-call framing in the D-330
debt residual (overturned by the Round-4 probe).
