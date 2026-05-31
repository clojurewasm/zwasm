# Platform-conditional gaps: `@panic` over widening shared `Error` — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/platform_panic_vs_error.md`](../rules/platform_panic_vs_error.md).

Auto-loaded when editing files that contain `comptime
builtin.target.{cpu.arch,os.tag}` branches. Codifies the
2026-05-22 incident in `src/engine/codegen/shared/entry.zig`:
a Win64-only `else` branch needed to do something, the
first attempt was `return Error.UnsupportedEntrySignature`,
which forced **every** Class A/C exhaustive `switch (err)`
caller to widen for a variant comptime-pruned on Mac/Linux.
The cascade hit 4+ unrelated call sites and required
re-doing the patch.

## The rule

When you face this exact shape:

```zig
if (comptime builtin.target.cpu.arch == .aarch64) {
    // ... live on Mac aarch64
    return ...;
} else if (comptime builtin.target.cpu.arch == .x86_64 and
           builtin.target.os.tag != .windows) {
    // ... live on Linux x86_64 SysV
    return ...;
} else {
    // <<< the temptation point >>>
}
```

**Do NOT** add a new variant to the function's declared
`Error` set just to give the else-branch something to
return. The else-branch is comptime-pruned on the supported
platforms, so the variant exists only to satisfy the else's
return type. Every caller's exhaustive switch then widens
for a phantom variant.

**DO** one of these, in order of preference:

### Option 1 (recommended): `@panic("...D-NNN")`

```zig
} else {
    // INVARIANT comment — see this rule
    @panic("<helper name>: no <arch+ABI> thunk yet (D-NNN)");
}
```

- `Error` set stays narrow → no caller widening.
- Mac/Linux: branch is comptime-pruned; zero observable
  change.
- Unsupported platform: build succeeds, runtime crashes
  with a D-tagged message if the gap is actually hit.
  No silent wrong-result.
- Discharge condition: implement the platform's thunk; the
  `@panic` line dies in the same diff.

### Option 2 (use only when caller-side recovery is meaningful)

Add a per-function error set (NOT widening the shared
`Error`):

```zig
pub fn callX(...) (Error || error{UnsupportedEntrySignature})!T {
```

This still forces direct callers to handle the new variant,
but **doesn't propagate to siblings**. Use only when:

- The caller has a meaningful recovery path (e.g. "skip
  this test", "fall back to interp"), AND
- The discharge path (implementing the platform thunk) is
  long enough that interim caller-side handling is real
  value, AND
- The variant is genuinely caller-observable (not a "we
  forgot to write the code yet" placeholder).

If any condition fails → use Option 1.

### Option 3 (rarely): `@compileError`

```zig
} else {
    @compileError("<helper name>: not implemented for this target (D-NNN)");
}
```

Use only when the platform reaching this branch is itself
a bug (e.g. WASI on a 16-bit target). Blocks the entire
build for that target; rarely the right call.

## Detection (auto-loaded recognition pattern)

When editing the listed files, the AI must mentally pattern-
match:

> "I want to add a new variant to `pub const Error = error{...}`
> AND the only motivation is making an `else { return ... }`
> in a `comptime builtin.target.*` branch compile."

If both clauses hold → **STOP**. Apply Option 1 instead.

The same trap exists for any shared error set across `src/
runtime/`, `src/api/`, `src/parse/`, etc. The narrower the
declared set, the more callers it touches.

## Reviewer checklist (apply during Step 4 Refactor /
pre-commit)

- [ ] Does the diff add a variant to a `pub const Error = error{...}`?
- [ ] If yes: is the new variant returned from a `comptime
      builtin.target.*` else-branch?
- [ ] If yes: does ANY caller use exhaustive `switch (err)`?
      `rg -nE 'switch \(err\)' src/ test/` to count.
- [ ] If yes: did the diff also touch those caller files?
      If `git diff --name-only | grep -E 'src/|test/'` shows
      callers added a new arm → SUSPECT API pollution. Use
      Option 1.

## Why this rule (case study)

Commit `4ec3f4cb` (2026-05-22 first attempt): added
`UnsupportedEntrySignature` to `entry.Error`. Mac+Linux
`zig build` exit 0 — the change looked clean. But on
windowsmini the `else` branch became live → 3 sites in
`entry.zig` resolved, but **4 call sites** in
`test/spec/spec_assert_runner.zig` +
`test/spec/spec_assert_runner_non_simd.zig` failed exhaustive
switch. Fixing those 4 sites needed mechanical patch of
existing `switch (err) { error.Trap => ... }` patterns —
work that should not exist for a Win64-only gap.

Commit `0c2474c2` (2026-05-22 redo): replaced
`Error.UnsupportedEntrySignature` with `@panic`. `Error`
returned to `error{Trap}`. Zero caller-side change. Mac /
Linux unaffected; Win64 still compiles (no exhaustive
issues); the @panic only fires if the specific helpers are
actually invoked.

## Cross-compile sanity check (use before push)

Before pushing a fix that touches comptime platform
branches:

```sh
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
```

The MinGW cross-compile (Mac → Win64-gnu) catches
exhaustive-switch and inferred-error-set issues in seconds
**without** the ~8min windowsmini test-all round-trip.
MSVC ABI variant still needs windowsmini for final
verification, but ~90% of Win64 issues are MinGW-equivalent.

## Forbidden anti-patterns

- **"Add the variant; callers will adapt"** — the cascade
  is exactly what makes this expensive.
- **"It's just 4 call sites; let me patch them"** —
  re-derive the cost: every future shared-Error widening
  pays the same cost; the policy choice is what scales.
- **`return error.<NewVariant>` without first asking
  "could @panic work here?"** — @panic is the default for
  "I haven't implemented this for this platform yet";
  caller-side recovery is the exception.

## Stale-ness

If the supported-platform set changes (e.g. Win64 ABI
thunks land; the `else` branch becomes empty), the @panic
sites die with the branch. The INVARIANT comment dies too.
That's fine — the rule itself stays useful for the next
gap.

## Related

- ROADMAP §14 forbidden list: "Unconscious API widening
  for platform-specific concerns" (candidate addition).
- `.claude/rules/no_workaround.md` — the broader principle.
- `.claude/rules/single_slot_dual_meaning.md` — sibling
  shape; this rule is the error-set specialisation.
- `src/engine/codegen/shared/entry.zig` callI32f64NoArgs /
  callF64i32NoArgs / callF64f32NoArgs (3 @panic sites).
