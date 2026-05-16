# Skip — assert_return after host-state-diverging skipped action

- **Status**: Closed (auto-discharged 2026-05-17 — `scripts/check_skip_adrs.sh` flagged 0 manifest consumers after the reftype-alias-to-i64 cohort at §9.9 / 9.9-l-1b-d093-d63 (commit `4c0ee3ae`) rewrote the affected directives. The Removal condition ("every `skip-adr-skip_host_state_diverged` line in manifests is replaced by a real directive") fired automatically via the d-63 distiller regen. Until 2026-05-17 the orphan went undetected because of a pre-existing `set -e` + `grep -rEc no-match → exit 1` bug in `check_skip_adrs.sh`; fixed in the same commit landing this Status flip.)
- **Date**: 2026-05-16 (originally landed as `skip-adr-host-state-diverged` at §9.9 / 9.9-l-1b-d093-d43; vocab-renamed at §9.9 / 9.9-l-1b-d093-d60 to satisfy `check_skip_adrs --gate` per D-131)
- **Author**: zwasm v2 / continue loop
- **Tags**: phase-9, skip-adr, spec-conformance, reftypes, host-state
- **Manifests covered**: 5 entries across `br_table`, `global`, `ref_is_null`, `select`, `table_*` corpora

## Context

Wast modules in the Wasm 2.0 reftype corpora (`ref_is_null.wast`,
`table_get.wast`, `table_set.wast`, …) commonly use a
`(invoke "init" (ref.extern N))` bare-action to populate host-
state into the module (externref slot in a table, an externref
global, etc.) before a series of observation asserts. Our
distiller's `action` arm rejects host-supplied non-scalar args
(externref / funcref are non-scalar arg kinds at the
`spec_assert` runner's `[5]ArgValue` dispatch matrix), emits
`skip-impl action-non-scalar-arg <field>`, and sets a per-
module `module_state_diverged = True` flag.

After the skipped action, any subsequent `assert_return` in the
same module-state segment expects results that depend on the
skipped action's side effects (e.g.
`ref_is_null.wast`'s `(assert_return (invoke "externref-elem"
(i32.const 1)) (i32.const 0))` requires the prior `init` to
have written a non-null externref into table 1[1]). The JIT-
observed value would be a function of the divergent state — so
the assert is no longer load-bearing for our spec
conformance.

## What v2 does today

The `module_state_diverged` flag lives in the distiller. While
True, the `assert_return` arm emits
`skip-adr-skip_host_state_diverged assert_return on
field={fn}` instead of executing the assert. The flag clears
on (a) the next `module` directive (state resets), or (b) the
next non-skipped `invoke-action` line (whose side effects
re-define the module's externref/funcref state cleanly
relative to the prior skipped action — see d-43's narrative in
`.dev/phase_log/phase9.md`). The runner's `classifySkipLine`
matches the `skip-adr-` prefix and routes the entry to
`skipped_adr++`.

## Why v2 declines

Honest execution of the skipped `init` action requires the
spec runner's argument-marshalling matrix to accept reftype
(`externref` / `funcref`) arg kinds and pass them via the
JIT's reftype-class scalar path (per ADR-0061 + the d-33
codegen plumbing). The argument-binding gap is at the runner
side: the `[5]ArgValue` matrix dispatches scalar (i32 / i64 /
f32 / f64) args + a single result class; reftype args don't
have an `ArgValue` representation yet.

That gap is part of the broader `runner-shape-gap` /
`non-scalar-arg` skip-impl backlog (top remaining classes in
the §9.9 drain queue per
[`handover.md`](../handover.md) Next-candidate list); honest
fix is the runner's argument-binding extension, not a per-fixture
ADR.

## What v2 needs to fix this honestly

Extend `spec_assert_runner_non_simd`'s dispatch ladder:

1. Add reftype `ArgValue` variant (`ref` carrying a `Value.ref`-
   encoded host pointer slot).
2. Plumb that variant through the `dispatchScalarResult` /
   `dispatchVoidResult` / `invokeActionShape` ladders so
   `(ref.extern N)` / `(ref.func $f)` / `(ref.null extern)` /
   `(ref.null func)` args bind cleanly to the JIT's reftype-
   class scalar path (per ADR-0061).
3. Once arg binding works, the distiller's
   `action-non-scalar-arg` skip-impl arm naturally retires
   (no longer triggers), `module_state_diverged` stays False
   across these modules, and downstream asserts execute end-
   to-end.

This is tracked under the §9.9 `non-scalar-arg` /
`trap-non-scalar-arg` skip-impl drain queue (the post-d-58
narrative in `handover.md`).

## Removal plan

When the spec_assert runner's dispatch ladder accepts reftype
args, the `module_state_diverged` flag stops getting set, and
the `skip-adr-skip_host_state_diverged` lines stop being
emitted at regen time. Retire the ADR's manifest references in
the same chunk that ships the reftype-arg extension. The ADR
itself stays as historical record per ADR-0029 Path B
conventions.

## Removal condition (machine-checkable)

> Every `skip-adr-skip_host_state_diverged` line in
> `test/spec/wasm-2.0-assert/**/manifest.txt` is replaced by a
> real `assert_return` directive (the prior `invoke-action`
> ran cleanly and set the host state the assert observes), and
> `grep -r 'skip-adr-skip_host_state_diverged'
> test/spec/wasm-2.0-assert/` returns zero hits.

## Implementation (per ADR-0029 Path B, since §9.9 / 9.9-l-1b-d093-d43)

The distiller carries a module-scoped `module_state_diverged`
Python bool. Set to True on `skip-impl action-non-scalar-arg`
(the `action` arm) and on its trap-axis sibling. Cleared on
`module` directive (state resets) and on every non-skipped
`invoke-action` (side effects re-define the state).
`assert_return` checks the flag first and emits
`skip-adr-skip_host_state_diverged assert_return on
field={fn}` when set. The pre-d-60 vocab was
`skip-adr-host-state-diverged` (no `skip_` infix); d-60
renamed it to the gate-conforming form so this ADR's filename
matches what `check_skip_adrs.sh` expects.

## References

- ADR-0029 (Path B `skip-impl == 0` enforcement + prefix-vocab
  rule)
- ADR-0050 D-2 (skip-ADR effectiveness gate)
- ADR-0057 (`spec_assert_runner_non_simd` factoring)
- ADR-0061 (reftype-class codegen plumbing)
- D-079 (cross-module imports umbrella — adjacent scope; reftype
  arg-binding is a sibling gap)
- D-131 (prefix-vocab gate cleanup — this ADR + paired
  `skip_cross_module_action.md` discharge that row)
- [`skip_cross_module_register.md`](skip_cross_module_register.md) —
  the paired `(register ...)` directive skip-ADR
- §9.9 / 9.9-l-1b-d093-d43 (`077ca871`) — first introduction
  of the `module_state_diverged` flag in the distiller (then
  emitted with the bare `cross-module-action` / `host-state-
  diverged` vocab)
- Wasm spec §3.4.4.4 / §4.4.10 (reftype semantics)
