# Stale .zig-cache binary path → false differential finding

**Date**: 2026-07-09 · **Context**: D-510 fuzz-diff extension validation

## What happened

While validating the extended `fuzz_exec` harness, a temporary fault
injection (`memoryBytes()[3] +%= 1`, for verifying the MEM-MISMATCH path)
was built, run, and then reverted. A subsequent smith-campaign run invoked
the runner binary **directly by its `.zig-cache/o/<hash>/` path** — but that
path was the *injected* build (each source edit compiles to a NEW hash dir;
old dirs stay). The campaign reported `MEM-MISMATCH … first diff at 0x3 …
jit=0x01` — exactly one "finding", which was the injection artifact, not a
real divergence. Re-running with the clean binary: 2008 modules, 0 mismatch.

Disambiguation that worked: run every candidate `.zig-cache` binary over the
COMMITTED corpora (known-green baseline) — the clean one reports 0
mismatched; each injected one reproduces its own signature.

## Rules

1. **Never reuse a `.zig-cache/o/<hash>/` exe path across source edits.**
   After any edit, re-resolve via the build system (`zig build <step>`), or
   pick the newest-mtime artifact AND verify it against a known-green
   baseline before trusting a finding from it.
2. **Fault-injection experiments must end with a clean-rebuild + green run**
   before any further investigation uses "the binary". An injection
   signature (fixed offset, ±1 delta) surfacing later = first suspect is a
   stale build, not a real bug.
3. A differential/fuzz "finding" whose shape mirrors a recent deliberate
   perturbation is presumed contamination until reproduced by a
   freshly-built runner.
