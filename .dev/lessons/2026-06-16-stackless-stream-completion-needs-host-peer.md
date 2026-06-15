# Stackless single-task stream/future COMPLETION needs a peer (host or 2nd task)

**Date**: 2026-06-16 · **Area**: WASI 0.3 CM-async (D-335 ζ2) · refs ADR-0187, ADR-0189

## Observation

zwasm hosts CM-async via the **stackless callback ABI, no fibers** (ADR-0187). A
guest async task that calls `stream.read`/`write` with no peer ready **parks
BLOCKED and returns control to the host callback loop** — the task is off the
stack with no held continuation. There is therefore **no single-task path to a
read/write rendezvous COMPLETION** (count > 0): completing the rendezvous
requires the *other* end to act, which needs one of:

1. a **second concurrent guest task** (a `Subtask` + a scheduler), or
2. a **host stream peer** (a WASI-P3 host interface — zwasm **Unit E**), or
3. **stack-switching** (`suspend`/`resume`) — explicitly OUT of scope (ADR-0187).

Evidence: `CanonicalABI.md` §Stream State (~1694–1722) — the rendezvous is
bipartite (reader-first parks, writer-first completes, and vice versa).
wasmtime's `tests/misc_testsuite/component-model/async/intra-streams.wast`
(~76–115) shows read-blocks-then-write-completes **only because it uses
stack-switching** (a *synchronous* lift, not the stackless callback path) — a
sub-ABI zwasm does not implement.

## What this means for wiring (single-task, testable NOW)

| Outcome | single-task? | needs |
|---|:-:|---|
| BLOCKED (read/write, no peer) | ✅ | — |
| DROPPED (read/write, peer dropped) | ✅ | drop the peer first |
| zero-length write | ✅ | completes per spec |
| **COMPLETED (count>0)** | ❌ | host peer (Unit E) / 2nd task / stack-switch |
| CANCELLED | ❌ | an async copy in flight |

## Rules

1. **Don't try to e2e-test a guest-to-guest stream COMPLETION in the single-task
   P3 runner** — it cannot happen without a peer. The WAIT-path payoff fixture
   (guest blocks on read → a write delivers STREAM_READ) **gates on Unit E** (a
   host stream peer) or a multi-task scheduler — NOT pure ζ2.
2. ζ2 read/write can still wire the BLOCKED/DROPPED/zero-length returns + the
   `Step → ReturnCode` mapping; element marshalling (Unit-C store/load) only runs
   on COMPLETION, so it defers with COMPLETION to Unit E.
3. The Zone-1 rendezvous (`SharedStream.read`/`write`) is correct and peer-agnostic
   — it's the *driver* (who supplies the peer) that's missing, not the logic.
