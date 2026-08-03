# An ungated "no X needed" doc claim rots into a lie the downstream pays for

- **Date**: 2026-08-03
- **Area**: build.zig `static-lib`; docs/migration_v1_to_v2.md; D-312
- **Trigger**: issue #153 / PR #154 (jtakakura) — building
  [zwasm-rust-sdk](https://github.com/jtakakura/zwasm-rust-sdk) against
  v2.3.0 failed to link with undefined `___zig_probe_stack`.

## Observation

`docs/migration_v1_to_v2.md` and the D-312 debt row both asserted:

> No `compiler-rt` shim is needed — Zig bundles it into the archive
> (v1 needed `-Dcompiler-rt`).

Measured (Zig 0.16.0): **false**. `Compile.bundle_compiler_rt` is
`?bool = null`, and `null` resolves to `kind == .exe or
isDynamicLibrary()` — a **static library never gets it**. The default
`zig build static-lib` archive holds only `libzwasm_zcu.o` and leaves
`__zig_probe_stack` (x86_64) plus the `__divti3`-class builtins
undefined. Reproduced the reporter's exact linker output in one command.

## Why it survived ~2 months

The claim was a **negative** ("no flag needed") and nothing exercised
it. `scripts/test_extlink.sh` — the one test that links through a
non-zig system linker — was never wired into CI **and** ran only on
the host where the claim happens to look true: on macOS/Linux the
system `cc` supplies `__divti3` from clang-rt/libgcc, so the gap only
bites on x86_64 (`__zig_probe_stack` has no non-Zig provider) and only
from a linker like rustc's. Host-shaped luck read as verification.

## Rule

- A doc claim of the form "you do **not** need X" is a test obligation,
  not prose. Either a check asserts it or it will drift — the reader who
  discovers otherwise is an external consumer, and they pay in a failed
  build, not a failed CI run.
- Prefer asserting the **positive artifact property** (`ar t` shows
  `compiler_rt.o`) over asserting the absence of a symptom on one host.
- When a claim proves false, correct the debt row too — D-312 had
  seeded the same sentence into user-facing docs.

## Landed

`-Dcompiler-rt=true` (PR #154, v1-parity spelling; default off is
byte-identical to the previous archive — verified). Docs + D-312
corrected; `test_extlink.sh` now builds with the flag, asserts
`compiler_rt.o` is in the archive, and runs on the CI extended leg.
