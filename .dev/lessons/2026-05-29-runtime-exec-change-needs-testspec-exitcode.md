# A runtime exec change must gate on test-spec with an EXIT-CODE check, not a summary grep

**Date**: 2026-05-29 (@ a4280043 → fixed next commit, cycle 149→150)
**Keywords**: 10.G, ref.test, RTT, @intCast panic, SIGABRT exit 134,
test-spec gate, ADR-0076 scope classification, summary-grep masking,
gate-coverage gap, any.convert_extern, untagged GC ref

## What happened

cyc149 landed `ref.test` exec (a runtime behaviour change). It shipped
green (`zig build test` + lint) + 2-host (ubuntu `zig build test`) but
carried a **latent crash**: `readObjKind` did `@intCast(v.ref)` to u32
BEFORE its heap-bounds check. `ref.test (ref struct)` can be reached with
an `anyref` holding a host pointer (an `any.convert_extern` result — a
value > u32::MAX), so the cast panicked → `SIGABRT` (exit 134) on the
spec corpus. gc return still "116" because the crash aborted the run
AFTER gc's summary line printed.

It slipped TWO ways:
1. The per-task gate ran `--fast` (`zig build test` only). A **runtime
   exec change** should classify to a **test-spec** gate (ADR-0076 D1) —
   `zig build test` (unit) doesn't run the corpus.
2. The manual corpus check used `... | grep -E "^\[gc "` — a **summary
   grep** that shows the gc line even when the process then aborts. The
   exit code (134) + a `panic|abort|signal` grep were never checked.

## Lesson

- **For any runtime exec/interp handler change, run the full spec corpus
  AND assert exit code 0**, e.g.:
  `"$BIN" test/spec/wasm-3.0-assert > out 2>&1; echo $?` then
  `grep -ciE "panic|abort|signal" out`. A summary-line grep is NOT
  sufficient — a crash on a later fixture prints earlier summaries first.
- **Bounds-check an untagged ref as u64 BEFORE casting to u32.** zwasm GC
  refs are untagged (a `Value.ref` u64 may be a GC offset OR a host
  pointer from extern-conversion). Any handler that treats `v.ref` as a
  heap offset must reject `v.ref >= heap.bytes.len` first (the cast
  panics on a > u32 value). The proper long-term fix is a tagged ref
  representation (deferred).

## Related

- ADR-0076 D1 (gate scope classification — runtime change → test-spec).
- `.dev/lessons/2026-05-29-gc-type-subtyping-is-rtt-blocked.md` (M3 covers
  compile failures; exec mismatches/crashes need the exit-code check).
- ADR-0116 (RTT) — the untagged-ref limitation surfaced here.
