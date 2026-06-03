# CallStackExhausted: diagnose runaway-vs-deep BEFORE raising the stack

**Date**: 2026-06-03 · **Context**: D-242 (go_* wasip1 fixtures trap on `_start`)

## Observation

`go_math_big.wasm` (Go's `math/big`) tripped `Trap.CallStackExhausted` at the
interp's 256-frame cap. The obvious read — "256 is too shallow for Go's runtime,
make the frame stack growable" — was scoped as a multi-cycle Runtime refactor.

It was the wrong diagnosis. One cheap experiment settled it: bump
`max_frame_stack` 256 → 8192 → **131072** (with a lazy heap overflow so the
Runtime struct stays small). go_math_big **still overflowed at 131072**. No
`math/big` program legitimately nests 131072 calls — so the interp is pushing
frames *unboundedly*. The bottleneck is not the cap; it's runaway growth.

Also ruled out by reading the code, not guessing: tail-call-as-frame-growth.
The interp tail-call correctly pops THEN pushes (`dispatch.zig:119/140` =
frame-replace, constant depth). The runaway is in some regular `call` path
(`mvp.invoke` pushFrame → re-enter `dispatch.run` → popFrame) where a call
never returns — an interp miscompile causing infinite recursion, or Go's
wasm runtime re-entry model that v2 mishandles.

## Rule

A fixed-limit exhaustion (`CallStackExhausted`, `StackOverflow`, OOM-at-N) has
two distinct causes: **(1) legitimately needs more** → raise/grow the limit;
**(2) runaway/leak** → a bug pushes without bound, and raising the limit only
delays the same crash. Distinguish them with ONE cheap experiment FIRST: raise
the limit far past any plausible legit value. Still crashes → it's runaway; do
NOT build the bigger/growable structure (wasted work) — find what grows
unboundedly. Crash clears → it was legit-deep; raise/grow is the right fix.

Corollary: don't infer "Go's runtime is deep" from a fixture name; measure.
And read the suspected mechanism (here: the tail-call pop/push order) instead
of assuming it.

Related: D-242 (re-diagnosed: runaway, not stack-size); D-243 (file-I/O, the
adjacent §11.1 work); same family as the re-probe-barriers and verify-by-disasm
lessons — verify the failure mode before scoping the fix.
