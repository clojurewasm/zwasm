# `File.stdout().writer()` is positional → two processes overwrite each other

**Date**: 2026-08-15 · **Citing**: `cef9708c8` (ADR-0210, 22 test runners) · maintenance

`std.Io.File.stdout().writer(io, buf)` goes through `Writer.init`, which sets
`.mode = .positional` with `pos: u64 = 0` (zig 0.16.0,
`std/Io/File/Writer.zig` 36-43 / 16). Positional writes go to an absolute
offset, so **every process starts writing at byte 0**. When two run steps
share one seekable stdout — a shell redirect, a CI log file, a captured build
step — the second silently overwrites the first instead of appending.
`writerStreaming` (`.mode = .streaming`) is what a process-stdout writer
wants; `initDetect` picks by whether the fd is a terminal.

It only shows up when stdout is seekable. Straight to a TTY, positional and
streaming look identical — which is why it survives interactive testing and
appears later under redirection.

**Measured on `main` (2026-08-15)**: `src/` was already clean — 8
`writerStreaming`, zero `.writer(`. `test/` was not: all 22 spec/edge runners
used `.writer()` until ADR-0210 converted them.

**Why this has its own entry**: the symptom is *"the same output keeps coming
back / the run did not re-execute"*, which reads exactly like a build-cache
staleness bug. It mis-triaged one for real — D-592 was opened claiming the
spec lanes got cached run steps, and cited
`2026-05-30-edge-runner-fixture-cache-false-coverage` as precedent. Both were
wrong; the actual cause of the repeated output was this writer. Before
blaming `has_side_effects` or the run-step cache, check whether two processes
are writing the same redirected stdout.

## Related

- `.dev/decisions/0210_spec_runner_enumeration_accounting.md` (the conversion)
- `.dev/lessons/2026-05-30-edge-runner-fixture-cache-false-coverage.md` (the
  bug this one was mistaken for)
- D-592 (the retraction)
