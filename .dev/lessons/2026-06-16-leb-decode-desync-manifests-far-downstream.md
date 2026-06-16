# A single-byte read of a multi-byte LEB immediate desyncs the decoder — the error surfaces far downstream

**Date**: 2026-06-16
**Context**: Front ③ GC corpus. A Guile-Hoot wasm-gc module failed zwasm
validation with `UninitializedLocal at op 0x20 (local.get)` in func #354 — a
definite-assignment error. Two layers of investigation chased the local-init
logic (grow-only bitset, reachability gating) before the real cause turned up:
not definite-assignment at all (D-453).

**Finding**: `ref.test`/`ref.cast`/`br_on_cast` read their heap-type immediate
as a single byte, but it's an SLEB128 (s33) — a concrete type index ≥ 64 takes
2+ bytes. For such an index the validator/lowerer advanced `pos` by only 1,
leaving a continuation byte (often `0x00`) that the dispatch loop then read as
the NEXT opcode (`0x00` = `unreachable`). That spurious `unreachable` poisoned
the frame's reachability, so a later `local.set` was skipped by the
"reachable-code-only" init-marker, and an even later `local.get` tripped a
genuine `UninitializedLocal` check. **The reported error was three hops removed
from the actual bug, in a different subsystem.**

**How to apply**: when a validator/decoder error looks *wrong for the
instruction it names* (here: a definite-assignment error on code that's
obviously assigned; wasm-tools validates the module), suspect an **upstream
immediate-decode-length bug** before deep-diving the named subsystem. A
desync makes the stream mis-aligned, so every error after the bad immediate is
noise. Fast triage: (1) confirm a reference tool (wasm-tools) accepts the
module → zwasm-side bug; (2) bisect by feature/boundary (here: the bug appeared
exactly at concrete type index 64 — the 1→2-byte LEB boundary — which a binary
search on a minimal repro pins immediately); (3) audit every immediate read for
"single-byte read of a value the spec encodes as LEB/SLEB" — they must use the
shared LEB reader (`init_expr.readTypedRef`/`readHeapType`), never `pos += 1`.
The boundary-valued minimal repro (idx 63 passes, idx 64 fails) is the decisive
signal that it's a width/encoding bug, not a semantic one. Cross-ref the front-③
bug thread (the real-toolchain corpus found 4 distinct validator/decoder spec
gaps the synthetic spec suite missed): [[validator-exact-eql-where-reftype-subtyping-required]].
