# Reference-runtime bumps: re-validate via the diff lanes; argv[0] is the only CLI divergence

**Date**: 2026-06-14 · **Context**: user directive to keep the reference runtimes
current (wasmtime + wasmer "are progressing"), landing alongside the §9.6 A3
wasmer second-oracle lane.

## Observation

Bumped the nixpkgs flake input 2026-04-27 → 2026-06-10, which carried **wasmtime
43.0.1 → 45.0.0** and **wasmer 5.0.4 → 7.1.0** — both reference oracles jumped two
major versions at once. Zig held at 0.16.0 (pinned via `zig-overlay`, independent
of nixpkgs). Re-ran the realworld differential against the updated runtimes:

- `test-realworld-diff`: zwasm == wasmtime 45.0.0 → **53/53 matched, 0 mismatch**.
- `test-realworld-diff-wasmer`: zwasm / wasmtime / wasmer 7.1.0 → **53/53 agree,
  0 REF-DISAGREE**.

A 2-major-version bump on BOTH oracles surfaced **zero semantic divergence** on the
corpus. The only cross-runtime difference seen was a CLI-launcher artifact, not a
runtime semantic: wasmtime (and zwasm) set WASI `argv[0]` to the fixture BASENAME,
wasmer uses the path arg VERBATIM — so every argv[0]-printing guest looked like a
spurious REF-DISAGREE until normalized. The lane runs wasmer from the corpus dir
with the bare basename (`.cwd = .{ .path = corpus_dir }`) so argv[0] matches.

## Rule

1. **Runtime bumps are low-risk here, but never assumed — re-validate** by running
   both diff lanes (`test-realworld-diff` + `test-realworld-diff-wasmer`) inside the
   updated `nix develop .#default` shell (the bare-host PATH keeps the old nix-profile
   wasmtime; the lane resolves whatever is first on PATH).
2. **argv[0] convention is THE cross-runtime CLI gotcha** — normalize it (basename)
   so the differential fires only on genuine semantic divergence, never on launcher
   policy. New reference oracles need the same normalization check.
3. **The Zig pin survives a nixpkgs bump** (zig-overlay's `"0.16.0"` key is not
   nixpkgs-version-derived) — verify `zig version` post-bump regardless.
4. **Bench-doc version strings are historical** (paired with the numbers measured at
   that version, append-only `bench/`) — do NOT retro-bump them on a runtime update.
