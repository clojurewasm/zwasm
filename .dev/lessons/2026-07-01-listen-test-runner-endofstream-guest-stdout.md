# `failed command: … --listen=-` after an all-green `zig build test`

**Date**: 2026-07-01 · **Area**: test infra / WASI fd / Zig 0.16 build runner

## Symptom

`zig build test` (or `test-all`) prints, near the top, a phantom failure:

```
test
+- run test w
x
failed command: ./.zig-cache/o/…/test … --seed=… --listen=-
```

…yet exits **0**, and `zig build test --summary all` says
`Build Summary: N/N steps succeeded; M passed`. Confusing — it looks like a
failure but every test passed.

## Root cause (verified, not just "cosmetic")

Zig 0.16's test binary runs in **server mode** (`--listen=-`) and speaks its
result protocol to the build runner over **stdout (fd 1)** and stdin (fd 0). A
zwasm **WASI unit test** that runs a guest which writes to stdout, with a live
`io` context but **no capture buffer**, hit `src/wasi/fd.zig`'s real-stream path
(`std.Io.File.stdout()`) and wrote guest bytes into **the same fd 1** the
protocol uses → the stream corrupted → the runner **panics on `EndOfStream`**
when the build closes the pipe, AFTER every test already passed and was counted.

Bisection proof: a minimal all-pass project (even 3000 trivial tests) is clean —
so it is NOT Zig-generic nor test-count/timing; it is a **specific test's
side-effect**. Running the flagged binary directly (no `--listen`) → `2991
passed; 0 failed`; with `--listen=- < /dev/null` → immediate `EndOfStream` panic.

## Fix

Guard the real-fd-1/2 write in `fd.zig` with `!@import("builtin").is_test`: a
test build must never route guest std streams to the process's real fd (they
belong to the harness). Same pattern already used by `platform/signal.zig:51`
for its fd-2 write. Production (CLI / C-API real-stdout default, which is the
documented `inherit_stdio` behavior) is unchanged; tests that assert on guest
output use a capture buffer (`host.stdout_buffer`), unaffected.

## Takeaway

- A phantom `failed command: … --listen=-` with exit 0 = the runner aborting on
  a corrupted/closed protocol pipe AFTER all tests pass, not a failing test.
  Trust the exit code + `--summary all`. Real failures still exit 1 (verified).
- Never write to the real process fd 0/1/2 in a `builtin.is_test` build.
