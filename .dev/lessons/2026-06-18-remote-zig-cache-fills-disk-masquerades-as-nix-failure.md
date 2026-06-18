# Remote ubuntu "nix-shell-env dependency failed" was a FULL DISK (.zig-cache 402G)

**Date**: 2026-06-18

## What happened

`run_remote_ubuntu.sh test-all` failed at `nix develop`:

```
error: Cannot build '/nix/store/...-zig-0.16.0.drv'.
       Reason: builder failed with exit code 1.
error: Cannot build '/nix/store/...-nix-shell-env.drv'.
       Reason: 1 dependency failed.
error: Build failed due to failed dependency
```

This LOOKS like a nix/flake dependency problem, but the derivation's `Last log
lines` showed the truth: `cp: error copying 'zig' ... No space left on device`
+ `note: build failure may have been caused by lack of free disk space`.

`df -h /` on ubuntunote: **444G/468G, 100% full, 397M free.** The culprit:
`~/Documents/MyProducts/zwasm_from_scratch/.zig-cache` had grown to **402 GB**.
Zig's build cache (`.zig-cache/o/<hash>/`) accumulates per-(build-config ×
commit) incremental artifacts with NO auto-prune; a long session of `test-all`
runs (× the `-Dtarget=x86_64-macos` and per-commit variants) bloats it without
bound.

## Fix

`rm -rf .zig-cache` (a pure regenerable build cache — safe). Freed 405 GB
(100% → 9%). `nix develop --command zig version` then builds the zig-0.16.0
derivation cleanly and the dev shell loads. First `zig build` after is cold
(slower); that's the only cost.

## Rule

- A remote `nix develop` / derivation build failing with a generic "dependency
  failed" → **check `df -h` FIRST**, before debugging the flake. The real error
  is in the derivation's `Last N log lines` (`No space left on device`).
- This is a Step 0.7 **non-code-gap** (the build env failed, `zig build test-all`
  never ran) → **re-kick, do NOT auto-revert** (D3 exception).
- Periodically prune remote `.zig-cache` (it grows unbounded across test-all
  runs). Related to but distinct from the Mac-host Defender `.zig-cache` scan
  (D-028). Consider a size-cap/prune in `run_remote_*.sh` if it recurs.
