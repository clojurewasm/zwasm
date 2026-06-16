# windows CRLF on LF-committed manifests → BadPathName, hidden by a non-gating skeleton runner

**Date**: 2026-06-16
**Context**: ADR-0174 windowsmini-hardening Phase-1 — the wasm-3.0-assert `pass=0` anomaly

## Observation

The `wasm-3.0-assert` runner reported `pass=0` across ALL 5 buckets on windowsmini
(assert_return un-evaluated, assert_invalid un-rejected) while ubuntu/Mac ran it
fine (pass=10234). Two compounding causes:

1. **windows CRLF + a `\n`-only split.** The corpus manifests are committed LF, but
   git autocrlf checks them out as CRLF on windowsmini. The runner did
   `splitScalar(manifest, '\n')` and passed each line to the parser WITHOUT trimming
   the trailing `\r` — so `module_path` ended in `\r` → `Dir.readFileAlloc` →
   `error.BadPathName` on Win64 (a `\r` is an invalid NT path char) → every module
   silently un-loaded. The other 4 runners (base/spec/wast/component) already did
   `std.mem.trim(raw, " \r\t")`; this runner was the lone miss. Mac/ubuntu (LF) were
   immune, so the per-chunk 2-host gate never saw it.

2. **A non-gating skeleton hid it.** The wasm-3.0-assert runner is a 10.T-2b WIP whose
   pass/fail counts do NOT propagate to its exit code, so `[run_remote_windows] OK`
   despite pass=0 — the ADR-0174 "OK-verdict-hides-pass=0" anomaly. A whole proposal
   bucket was un-tested on Win64 behind a green gate.

The root cause was invisible until a diagnostic was added: the runner *swallowed* the
read failure (`readFileAlloc catch { null; continue }`). Adding a `MODULE-READ-FAIL:
<errno>` print on that path immediately surfaced `BadPathName ×364`.

## Rule

- **CRLF gotcha**: any runner/parser that splits committed text on `\n` MUST trim
  `\r` (`std.mem.trim(line, " \r\t")`) — a windows checkout makes LF-committed files
  CRLF. When adding a NEW such runner, mirror the existing ones' trim (grep for the
  pattern); a host-specific `BadPathName`/parse oddity with clean-looking paths is the
  tell (the bad char is an invisible trailing `\r`).
- **No silent skip on a load path**: a swallowed `readFileAlloc`/`parse` error
  (`catch { null; continue }`) on a corpus runner hides exactly this class. Surface it
  (ADR-0174). A non-gating skeleton runner that reports counts-without-gating its exit
  code is a gate-integrity hole — a green host verdict can hide a fully-broken bucket.

## See also

- ADR-0174 (windowsmini-hardening); diagnostic @60f3706d; fix @02592aa8.
- [[hardcoded-corpus-subset-hides-whole-op-families]] — sibling "the gate looked green
  but a whole class was untested" theme.
