# Out-lining once-called inlined handlers is size-NEUTRAL (a giant symbol ≠ duplication)

- **Date**: 2026-07-16
- **Area**: engine/codegen dispatch; binary size (ADR-0204 campaign)
- **Trigger**: D-521 stage A — converting `dispatch_collector.dispatch()`
  from `inline for` + `@call(.auto)` to a comptime fn-pointer table,
  expecting `engine.codegen.arm64.emit.compile` (one 707 KB `__text`
  symbol) to shrink by the out-lined handler share.

## Observation

Measured (ReleaseSafe arm64 CLI, on top of D-522 stage 1):

- `emit.compile`: 707,492 B → 707,540 B — **unchanged**.
- Whole binary: 4,173,736 → 4,202,536 B — **+28.8 KB** (+213 handler
  symbols; part of the delta is symtab/strtab, not code).
- Change reverted.

## Why (re-derivable)

A function inlined into its **single** call site is not duplicated —
the code exists exactly once, merely aggregated under the caller's
symbol. Out-lining it moves the same bytes behind a `call` and ADDS
call overhead + a symbol-table row. Per-symbol size attribution
(`nm` next-addr − addr) makes such a caller look like a monolith to
attack, but symbol size ≠ recoverable size. Contrast D-522 stage 1
(same campaign, same day): there the bodies were monomorphized into
**64 copies each** (per-slot comptime K) — genuine duplication — and
sharing them recovered −1.08 MB. **The question that predicts the
outcome is "how many call sites / instantiations share this code?",
not "how big is the symbol?"**

Same family as the D-507 scalar-elision retrospective ("biggest
lever" refuted by measurement): size/perf hypotheses from symbol
attribution or peer-project claims (here from_cljw_05's "table-driven
encoder typically shrinks 50–80%") must be probed with the cheapest
reversible experiment before scheduling a migration campaign.

## Residual

The per-op-file migration of the remaining ~161 legacy switch arms
(ADR-0074 trajectory) and O(1) table dispatch remain *maintainability/
compile-speed* options — pursue them on their own merits if ever
measured to matter, never as a size lever (D-521 discharged).
