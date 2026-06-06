# ADR-0168 — v0.2 / v0.3 scope unblock; dogfooding done; never-idle; Threads first

**Status**: Accepted (user-directed 2026-06-06)
**Deciders**: user + loop
**Touches**: ROADMAP §1.3 (v0.2.0 line), §9 phase scope (opens Phase 17), §3.3 (deferred-to-v0.2),
`.dev/proposal_watch.md`. Filed per §18.2 BEFORE any v0.2 implementation code (deviation watch).

## Context

Phase 16 (完成形) drove the v0.1 surface (C/Zig/CLI), memory-safety, and actionable debt to completion.
The frozen invariant (ADR-0156) held v0.2 feature work as **user-direction-gated** and forbade autonomous
release/tag. On 2026-06-06 the user gave three load-bearing directives:

1. **v0.2 AND v0.3 feature work is UNBLOCKED** — "v0.2, v0.3 ですら進めていい（解除）"; "AIが思いのほか早い
   のでどんどんやろう." The loop may now autonomously pursue the v0.2.0 line (and beyond).
2. **ClojureWasm v1 dogfooding is DONE** — "cw v1 側からもう成功している（完了)." The D-264 / D-075 /
   ADR-0109-Removal dogfooding gate is satisfied.
3. **No idling; keep the system always working** — D-279-class issues must never be "left alone"; the loop
   sweeps remaining work (`.dev/remaining_sweep.md`) when between features.

ADR-0156's **no-autonomous-release / no-tag** invariant is RECONFIRMED by the user ("もちろんタグは切らない").
v0.2/v0.3 features are pursued for capability/completeness, NOT toward a version tag.

## Decision

1. **Open ROADMAP Phase 17 = the v0.2.0 feature line** (autonomous, per this ADR). Sequence (proposal_watch +
   §1.3): **17.1 Threads (atomics + shared memory)** FIRST (well-scoped, self-contained, builds on existing
   memory ops; the ZirOps are already enumerated in `zir_ops.zig`), then wide-arith / custom-page-sizes /
   relaxed-SIMD-residuals, then the large surfaces (Component Model, WASI 0.2 → §18 v0.3). Web-only proposals
   (JS Promise Integration, ESM, Web CSP) stay **SKIP**.
2. **Single-threaded substrate stands** (no real concurrency yet; Phase-14 concurrency is separate, D-021).
   Atomic load/store/rmw/cmpxchg = **alignment-checked seq-cst memory ops** (atomicity trivially satisfied
   single-threaded; misaligned → trap). `atomic.fence` = no-op. `wait`/`notify` get a minimal single-threaded
   semantics (wait on non-shared → trap; notify → 0 waiters) until real threads land. Shared-memory flag
   parsed + validated; the backing is the same linear memory (no cross-thread sharing yet).
3. **Inviolable principles unchanged** (P3/P6 single-pass, no optimising tier; per-op file pattern ADR-0023
   §4.5; 3-host gate ADR-0076). v0.2 ops follow the same TDD per-op-chunk discipline as v0.1.
4. **D-264 discharged** (dogfooding done); **D-075** retires when ADR-0109 flips `Accepted → Closed`
   (next sweep — the dogfooding-survival predicate is met per the user).

## Consequences

- The loop now has a large high-value forward track (v0.2/v0.3) → the "minimal idle turn" steady-state is
  retired (handover NEVER-IDLE protocol). `.dev/remaining_sweep.md` is the between-features sweep source.
- No release/tag/cutover ever from the loop (ADR-0156). Phase 17+ is capability work, not a version march.
- proposal_watch.md + ROADMAP phase widget updated to reflect Phase 17 IN-PROGRESS.

## Removal condition

This ADR is descriptive of a standing user authorization; it does not retire. Per-feature ADRs (e.g. a
threads-memory-model ADR if the single-threaded atomic semantics need a load-bearing choice) are filed as the
work surfaces.
