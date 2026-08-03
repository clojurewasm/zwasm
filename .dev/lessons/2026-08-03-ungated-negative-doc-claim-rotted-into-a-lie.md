# An ungated "no X needed" doc claim rots into a lie the downstream pays for

- **Date**: 2026-08-03
- **Area**: build.zig `static-lib`; docs/migration_v1_to_v2.md; D-312
- **Trigger**: issue #153 / PR #154 (jtakakura) — building
  [zwasm-rust-sdk](https://github.com/jtakakura/zwasm-rust-sdk) against
  v2.3.0 failed to link with undefined `___zig_probe_stack`.

## Observation

`docs/migration_v1_to_v2.md` and the D-312 debt row both asserted "no
`compiler-rt` shim is needed — Zig bundles it into the archive (v1
needed `-Dcompiler-rt`)". Measured (Zig 0.16.0): **false**.
`Compile.bundle_compiler_rt` is `?bool = null`, and `null` resolves to
`kind == .exe or isDynamicLibrary()` — a **static library never gets
it**. The default archive holds only `libzwasm_zcu.o`, and the
reporter's exact linker output reproduced in one command.

## Why it survived ~2 months

The claim was a **negative** ("no flag needed") and nothing exercised
it. `scripts/test_extlink.sh` — the one test that links through a
non-zig system linker — was never wired into CI, and the *shape* of the
gap hid it from the hosts anyone did run. Per-target measurement:

| target            | `__divti3`-class | `__zig_probe_stack` |
|-------------------|:----------------:|:-------------------:|
| aarch64-macos     | undefined        | not referenced      |
| x86_64-macos      | undefined        | **undefined**       |
| x86_64-linux-gnu  | undefined        | not referenced      |
| x86_64-windows-gnu| undefined        | not referenced      |

The `__divti3` class always resolves against the consumer's own runtime
(clang_rt / libgcc / Rust's `compiler_builtins`), so it never bites.
`__zig_probe_stack` has no non-Zig provider — and it is referenced on
exactly one target, the one nobody's gate linked externally. Host-shaped
luck read as verification.

## Rule

- A doc claim of the form "you do **not** need X" is a test obligation,
  not prose. Either a check asserts it or it drifts — and the reader who
  discovers otherwise is an external consumer paying in a failed build.
- Assert the **positive artifact property** (`ar t` shows
  `compiler_rt.o`) over the absence of a symptom on one host.
- When a claim proves false, correct the debt row too — D-312 is where
  this sentence was seeded before it reached user-facing docs.

Landed: `-Dcompiler-rt=true` (PR #154; default off byte-identical to the
previous archive — verified), docs + D-312 corrected, `test_extlink.sh`
asserts the archive member and now runs on the CI extended leg.
