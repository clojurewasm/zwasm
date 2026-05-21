---
name: platform-panic-vs-error-widening
description: Widening a shared `Error` set for a comptime-pruned platform branch pollutes all callers; `@panic` is the cheap default
metadata:
  type: feedback
---

# `@panic` over widening shared `Error` for platform-only gaps

**Date**: 2026-05-22
**Keywords**: Win64, D-022, Error set widening, exhaustive switch, comptime branch, entry.zig, @panic, MSVC, MinGW cross-compile
**Citing**: `4ec3f4cb` (first attempt, reverted-in-effect by next), `0c2474c2` (the @panic redo), `.claude/rules/platform_panic_vs_error.md` (system-level defense)

## The trap

`src/engine/codegen/shared/entry.zig` had 3 Class B mixed-class
helpers with a `comptime builtin.target` branch:

```zig
if (...aarch64...) { ... }
else if (...x86_64 sysv...) { ... }
else { return Error.UnsupportedEntrySignature; }   // ← Win64 only
```

The first attempt added `UnsupportedEntrySignature` to the
shared `Error = error{Trap}`. On Mac/Linux `zig build` was
green because the else-branch was comptime-pruned → the new
variant was never inferred into any caller's switch
obligation. On windowsmini the else-branch became live →
**4 unrelated call sites** in test runners that had
`switch (err) { error.Trap => ... }` failed with
"exhaustive switch must handle all possibilities".

The cost: a second commit walking 4 callers. Each one was
calling a Class A helper (not Class B mixed!) but inherited
the widened error set because the type was shared.

## The fix

Revert to `@panic`. The shared `Error` stays narrow:

- Mac/Linux: comptime-prune; zero observable change.
- Win64: build compiles (no new error variant → no caller
  obligation); the actual mixed-class helpers crash at
  runtime with a D-022 tag *only if invoked*.

```zig
} else {
    @panic("Class B mixed-class entry helper: no Win64 thunk yet (D-022)");
}
```

## Why this happens

Three reinforcing factors:

1. **The expedient fix matches the natural Zig idiom**: when
   a function declares `Error!T`, returning `Error.X` is
   the obvious shape. The compiler accepts "add a variant"
   as the path of least resistance.
2. **Comptime branch hides the cost**: Mac/Linux see no
   change → green build is misleading. Cost surfaces only
   on the unsupported-platform build.
3. **Shared `Error` set is highly imported**: every caller
   inherits the obligation. Widening = O(N) caller burden
   for a 1-platform concern.

## What to do differently (auto-loaded in
`.claude/rules/platform_panic_vs_error.md`)

Default = `@panic`. Reserve error widening for cases where
caller-side recovery is meaningful AND the discharge path
is long. Always cross-compile (`-Dtarget=x86_64-windows-gnu`
on Mac) before pushing platform-conditional changes.

## Cross-compile workflow discovery (paired finding)

The same incident surfaced that **Mac local cross-compile
`zig build -Dtarget=x86_64-windows-gnu` succeeds in
seconds** and catches the same compile errors as a
windowsmini round-trip (which costs ~8 min for test-all).
Catches ~90% of Win64 issues at Mac iteration speed.

Workflow integrated into
`.dev/phase9_13_0_close_plan.md` §0.2.1 as a 4-tier
layered loop (L0 cross-compile → L1 rsync+build → L2
test → L3 final commit/push/test-all).

## Forbidden anti-patterns

- "Add the variant; callers will adapt" — the cascade
  cost is exactly what makes this expensive.
- "Just patch the failing switches" — re-derive the
  pattern at the source; the next time a platform branch
  needs an else, you'll re-pay.

## Related

- `.claude/rules/platform_panic_vs_error.md` — the
  auto-loaded rule.
- `.claude/rules/single_slot_dual_meaning.md` — sibling
  shape (one slot, two semantic axes); this lesson is the
  error-set specialisation.
- `.claude/rules/no_workaround.md` — broader principle.
- ROADMAP §14 forbidden list (candidate: "Unconscious API
  widening for platform-specific concerns").
