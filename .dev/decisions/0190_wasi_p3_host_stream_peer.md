# 0190 — WASI-0.3 Unit E: the host stream peer (unlocking guest read/write COMPLETION)

- **Status**: Accepted 2026-06-16
- **Revision note (2026-08-12)**: the sibling `component_wasi_p3_host.zig` this ADR reserved now exists — ADR-0207 (D-444 three-way split) delivered it; the host-stream peer engine itself stayed in the substrate (`component_wasi_ctx.zig`) reaching P3 via `WasiP2Ctx.P3Hooks`.
- **Author**: claude (autonomous, WASI-0.3 campaign D-335 Unit E; survey of `component_wasi_p2.zig` host-interface wiring + `async.zig` `SharedStream` + `canon.zig` element store/load + the WASI-P3 `cli/stdio` wit).
- **Composes with**: ADR-0189 (ζ2 — guest-side canon async builtins; deferred read/write COMPLETION here), ADR-0188 (P3 runner), ADR-0187 (stackless callback ABI). Within ROADMAP §9.0 Front D, Unit E.

## Context

ζ2 wired every guest-side canon stream/future builtin, but a guest-to-guest
read/write **COMPLETION cannot occur single-task** (lesson `2026-06-16-stackless-
stream-completion-needs-host-peer`): the blocked op returns to the callback loop
with no held continuation, so no second actor exists. The missing actor is a
**host stream peer** — the host implementing the *other* end of a stream the
guest reads/writes. That is Unit E.

Survey findings: a host (Zone-3) **can drive `SharedStream.read`/`write`
directly** (they are pure rendezvous logic). Element bytes are moved by
`canon.zig` `store`/`load` (inputs: a `CanonContext` = memory + allocator, a
typed `Value`, a `CanonType`, a guest `ptr`); `WasiP2Ctx.mem_instance` supplies
the memory. `p2StreamFutureCopy` currently traps (`error.OutOfBounds`) on
COMPLETION(n>0) precisely because that marshalling is unwired.

## Decision

**Model the host as a registered peer on a `SharedStream`: the host interface
trampoline records itself as the stream's host-side end, and the guest's
`stream.read`/`write` rendezvous against it — completing the copy, with bytes
marshalled via `canon.store`/`load`.** No scheduler, no fibers (ADR-0187 intact):
the host peer acts synchronously at the guest's rendezvous call.

**First interface (smallest viable): `wasi:cli/stdout.write-via-stream`** — the
guest passes a `stream<u8>` it writes; the host reads it and writes the bytes to
fd 1. Chosen because: (1) one fixed direction (host always reads); (2) stdout is
always write-ready (no polling); (3) element type `u8` (scalar — no nested
marshalling); (4) guest `stream.drop-writable` → host observes DROPPED + flushes.

Flow (stackless, synchronous):
1. Guest calls the host import `write-via-stream(readable_handle)` (a P2-style
   `canon lower` import, classified via `adapter.classifyImport` → a new P3
   `P2Op`/host-op). The trampoline marks the stream's host end as a pending
   READER on its `SharedStream` (`shared.read`), recording the host as peer.
2. Guest calls `stream.write(writable, ptr, n)` → `p2StreamFutureCopy` →
   `SharedStream.write` rendezvous with the host's pending read → COMPLETED(n).
   The COMPLETION path now marshals: `canon.load` the `n` `u8` elements from
   guest memory at `ptr` into a host buffer, host writes them to fd 1.
3. Guest `stream.drop-writable` → host sees DROPPED → flush/close.

This makes the **first guest stream.write COMPLETION + element marshalling +
(if the guest blocks) the WAIT-path** all reachable e2e.

## Alternatives rejected

- **A general async scheduler / multiple guest tasks** — heavier; the host peer
  is the spec-intended driver for host-backed streams and unblocks COMPLETION
  with far less machinery. (Multi-guest-task concurrency can come later if a
  pure guest-to-guest stream corpus needs it.)
- **stdin read-via-stream first** — rejected as the *first* slice: a host-as-
  writer must supply input data + handle EOF, slightly more state than host-as-
  reader draining to a fixed sink (stdout).
- **Wire marshalling into `p2StreamFutureCopy` generically now** — deferred to
  this interface so the first marshalling has a concrete consumer + e2e test
  (avoids speculative un-exercised code).

## Consequences

- A new P3 host-interface surface grows in/near `component_wasi_p2.zig` (or a
  sibling `component_wasi_p3.zig` host module) + new `P2Op`/adapter entries.
- `p2StreamFutureCopy`'s COMPLETION branch gains real `canon.load`/`store`
  marshalling (the `error.OutOfBounds` trap is replaced) — first exercised by the
  stdout fixture.
- Implementation is multi-slice (TDD): (E1) the host-peer registration + a
  guest-write→host-read COMPLETION of `u8` to stdout (capture-asserted) → (E2)
  the WAIT-path variant (guest blocks, host completes, callback re-entered) →
  (E3) stdin read-via-stream → broader P3 interfaces. Each lands green per D-335.
