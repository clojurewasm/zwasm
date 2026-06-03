# An ambiguous trap message hides the raise site — probe the EXACT site

**Date**: 2026-06-03 · **Context**: D-242 (go_* wasip1 fixtures trap on `_start`)

## Observation

`go_math_big.wasm` trapped `stack_overflow` / "call stack exhausted". That message
mis-led **two** wrong diagnoses before the third was correct:

1. "The interp's 256-frame call stack is too shallow." → scoped a growable-frame
   refactor. WRONG.
2. "It's runaway frame growth (still overflows at max_frame_stack=131072)." Also
   WRONG — and the 131072 bump "still overflowing" was a confound (the interp
   `pushFrame` probe never fired; frame_len stayed <100).
3. **Correct**: the trap is `Trap.StackOverflow` from `frame.pushLabel`
   (frame.zig:99) — the per-frame **LABEL** stack `max_label_stack = 128`, which
   is strictly less than the validator's `max_control_stack = 1024`. go_math_big
   has a function nesting >128 control blocks; the validator accepts it, the
   runtime label buffer overflows. Raising `max_label_stack` → 1024 → it exits 0.

The root confusion: `trap_surface.zig:89` maps **both** `error.StackOverflow` AND
`error.CallStackExhausted` to the SAME "call stack exhausted" message. So a label-
stack overflow, an operand-stack overflow, a frame-stack overflow, and a tail-call
underflow are indistinguishable from the user-facing trap. I assumed "call stack" =
frame stack and chased the wrong limit twice.

## Rule

When a fixed-limit exhaustion traps, **find the EXACT raise site before scoping a
fix** — do not infer it from the trap message, especially when one message is
shared across several distinct `return error.X` sites (grep ALL of them). The
cheapest probe: a one-line `std.debug.print` at each candidate raise site, then run
the fixture; exactly one fires and names the real limit. Two diagnoses here were
wasted because I reasoned from the message and from plausibility ("Go's runtime is
deep") instead of instrumenting the sites.

Second rule (D-241 family): a RUNTIME limit must not be stricter than the
VALIDATOR limit it mirrors. `max_label_stack` (128) < `max_control_stack` (1024) is
the same drift as D-241's verifier ceiling (256 vs 1024). Whenever a runtime fixed
buffer bounds something the validator also bounds, source both from one constant.

Caveat on the fix: the consistent value (1024) is right, but `label_buf` is INLINE
in Frame — [1024] makes Frame ~20KB → Runtime ~5MB + 8x per-call copy + a stack-
allocated test segfaults. The fix is a lazy per-frame overflow (small inline + heap
spill), not a naive inline bump. Measuring the cost stopped a bad "ship the raise".

Landed (`7806936f`): `label_buf [128]` inline + lazy `label_overflow []Label` (cap =
`zir.max_control_stack`, freed at popFrame); `max_label_stack` sourced from the shared
constant. All 9 `go_*` realworld fixtures now exit 0 (realworld-run 55/55, 0 SKIP-WASI).

Related: D-242 (this); D-241 ([[2026-06-03-sanity-check-must-share-the-real-gates-constant]]);
[[2026-06-03-reprobe-blocked-by-barriers-before-scoping]] (verify the failure mode first).
