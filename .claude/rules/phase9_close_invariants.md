---
paths:
  - ".dev/ROADMAP.md"
  - ".dev/handover.md"
  - ".dev/debt.md"
  - "test/spec/spec_assert_runner_base.zig"
  - "src/zwasm.zig"
  - "build.zig"
---

# Phase 9 close invariants (auto-loaded; non-bypassable until Phase 9 = DONE)

Auto-loaded when editing ROADMAP / handover / debt / spec runner /
zwasm.zig facade / build.zig. Codifies the **honest-accounting**
discipline established by ADR-0104 after the 2026-05-22 4-agent
audit found three §9.x rows had been prematurely `[x]`-flipped
against drift-amended criteria.

## Why this rule exists

The audit established (cited in `.dev/phase9_close_master.md` §2)
that:

- §9.13-0 [x] was flipped while Windows had 3196 SKIP-WIN64-*
  emissions on Wasm-1.0-core MUST-PASS fixtures (workarounds, not
  legitimate deferrals).
- §9.12-F [x] was flipped against ADR-0102's per-row predicate
  while row text still claimed literal "< 15".
- §9.12-I [x] was flipped while c_api / Zig API Wasm-2.0
  utilisation tests didn't exist.

User directive (2026-05-22): "新セッションから迂回できない原理的な
仕組みをつくっておきたい" — make the invariants non-bypassable for
a fresh session. This rule + `scripts/check_phase9_close_invariants.sh`
together make a clean-session `/continue` cycle land on the truth
unconditionally.

## The Phase 9 = DONE invariants

These conditions MUST all hold before any of §9.13-0 / §9.12-F /
§9.12-I / §9.13 may be `[x]`-flipped. The check script enforces
them mechanically.

### I1 — Zero SKIP-WIN64-* token emission

`test/spec/spec_assert_runner_base.zig` MUST NOT emit any of:

- `SKIP-WIN64-EXHAUSTION` (D-162; closed by ADR-0105 JIT-prologue
  stack-probe)
- `SKIP-WIN64-CALL-INDIRECT-TRAP` (D-163; closed by codegen-bug
  spike)
- `SKIP-WIN64-MULTI-RESULT` (D-164; closed by ADR-0106 multi-result
  ABI redesign)

Verification: grep emission sites in the runner; all 3 arms must
be removed. `windowsmini` test-all must PASS the corresponding
`assert_exhaustion` / `assert_trap as-call_indirect-last` /
`assert_return type-all-*` fixtures.

### I2 — c_api Wasm-2.0 utilisation tests present

Wasm-2.0 c_api utilisation tests MUST exist as **in-source `test
"..."` blocks** inside `src/api/instance.zig` (per project idiom —
existing `wasm_engine_new` / `wasm_instance_new` / `wasm_func_call`
tests follow the same pattern at lines 1000+; `zig build test`
discovers them via the core test runner).

Required test block name prefixes (substring grep):

- `wasm 2.0 reftype c_api round-trip` — funcref / externref
  args+results marshalling through `wasm_func_call`.
- `wasm 2.0 bulk-traps via c_api` — `memory.copy` / `table.init`
  OOB → `wasm_trap_t*` from `wasm_func_call`.
- `wasm 2.0 mixed-exports c_api walk` — `wasm_instance_exports()`
  returning multiple `wasm_extern_kind`s (func/memory/table/global).
- `wasm 2.0 cross-module funcref via wasm_instance_new` —
  imports[] threading funcref from instance A into instance B.

Per audit Agent 2 §A.2 + §D + project c_api test idiom (in-source
test blocks; `test/c_api/` does not exist by design). Per master
plan §5.2 (updated 2026-05-22 to reflect idiom). Per ADR-0104 D1.3.

### I3 — Zig facade minimum subset implemented

`src/zwasm.zig` MUST export public top-level types per ADR-0025
minimum subset:

- `pub const Runtime` (with `init(alloc, .{})` + `deinit()`)
- `pub const Module` (with `parse(&rt, bytes)` + `deinit()`)
- `pub const Instance` (with `module.instantiate(.{})` + `invoke(...)` + `deinit()`)
- `pub const Value` (tagged union for i32/i64/f32/f64/v128/funcref/externref)

Plus an in-source `test "zwasm facade Wasm 2.0 ..."` block in
`src/zwasm.zig` exercising them (per project idiom — `zig build
test` discovers via core test runner).

Per audit Agent 2 §B + §D. Per master plan §5.2 (idiom-corrected
2026-05-22). Per ADR-0104 D1.3.

### I4 — `wast_runtime_runner` (smoke) in `test-all`

`build.zig` MUST wire the **smoke** step
(`run_wast_runtime_smoke`, exercising `wast_runtime_runner` against
`test/runners/fixtures/`) into the `test-all` aggregate step. The
**wasmtime_misc full-corpus** step (`run_wasmtime_misc_runtime`)
is intentionally NOT in test-all per build.zig:454 comment —
deferred to §9.6 / 6.E interp-behaviour-bug investigation (separate
concern; D-072 etc).

Currently satisfied at build.zig:616
(`test_all_step.dependOn(&run_wast_runtime_smoke.step)`); Agent 2's
"NOT in test-all" finding mis-identified the deferred wasmtime_misc
step as the c_api Instance-path test (they share the same
`wast_runtime_runner_exe` binary).

Per ADR-0104 D1.4.

### I5 — Zero `blocked-by: trigger-not-fired` debts on Phase-9-scope features

`.dev/debt.md` MUST NOT have any row whose `Status:` text contains
both:
- `blocked-by: trigger-not-fired` (or equivalent priority-deferral
  phrasing), AND
- a feature that is Phase-9-scope per ROADMAP §9 (Wasm 2.0,
  3-host, c_api/Zig API Wasm-2.0 use).

Specifically: D-094 + D-062 + D-164 must NOT carry such framing
(per ADR-0104 D3 reframe). They are mechanical-precedent-exists
implementations that should be either:
- `now` (currently being implemented), or
- `blocked-by: ADR-XXXX Accept` (a real design dependency).

### I6 — ADR-0105 + ADR-0106 Accepted

Both companion ADRs MUST be `Status: Accepted` before §9.13-0 [x].
User collab review at §9.13 hard gate handles the flip.

### I7 — Phase-9-close master plan ACTIVE

`.dev/phase9_close_master.md` MUST exist with `Doc-state: ACTIVE`
header. handover.md MUST point at it.

## The check script

`scripts/check_phase9_close_invariants.sh` verifies I1–I7 mechanically:

```sh
bash scripts/check_phase9_close_invariants.sh --gate
```

Exit 0 = all invariants hold (Phase 9 = DONE eligible).
Exit non-0 = at least one invariant FAILed; cite which.

The script is **run at `/continue` Resume Step 5d** (per master
plan §4 Phase C). A fresh session lands on a FAIL until Tier-1
work fully lands.

## Forbidden edits

The following ROADMAP edits are §18.3 violations under this rule:

- Marking §9.13-0 / §9.12-F / §9.12-I / §9.13 `[x]` while
  `check_phase9_close_invariants.sh --gate` FAILs.
- Amending an exit text in §9.13-0 / §9.12-F / §9.13 to legitimize
  a SKIP-WIN64-* token (= the workaround-masquerade pattern ADR-0104
  rejected).
- Adding a new `SKIP-WIN64-*` token to ADR-0078 taxonomy without
  ALSO (a) filing a debt row whose `blocked-by:` names a concrete
  closing-ADR path, AND (b) adding the invariant to this rule's I1.

## Reviewer checklist

When reviewing a PR / commit that edits any of the auto-load paths:

- [ ] If the commit removes a `SKIP-WIN64-*` arm from
      `spec_assert_runner_base.zig`, does the corresponding
      D-162/D-163/D-164 close commit ALSO land in the same chunk?
- [ ] If the commit edits §9.13-0 / §9.12-F / §9.12-I / §9.13
      checkbox state, does
      `bash scripts/check_phase9_close_invariants.sh --gate` exit 0?
- [ ] If the commit adds a new SKIP token, is the I1 list in this
      rule updated?
- [ ] If the commit edits `src/zwasm.zig`, does it remove any of
      the `Runtime` / `Module` / `Instance` / `Value` facade
      types? (forbidden until v0.2 ADR amends ADR-0025).
- [ ] If the commit edits `build.zig`'s test-all aggregate, does
      it remove `wast_runtime_runner`? (forbidden — closed I4
      requirement).

## Stale-ness — when does this rule dissolve

This rule retires when **Phase 9 = DONE** per master plan §6 exit
predicate. Concretely:

1. ADR-0104 Status flips `Closed (Phase 9 DONE)`.
2. ADR-0105 + ADR-0106 land their implementations + close
   D-162/D-163/D-164.
3. `scripts/check_phase9_close_invariants.sh --gate` exits 0.
4. §9.13-0 / §9.12-F / §9.12-I re-flipped `[x]` with cited SHAs.
5. §9.13 collab gate cleared.
6. Phase Status widget advances to `9 | DONE`.

When that happens:
- This rule's body becomes informational reference (kept for
  Phase-10+ "what does Phase 9 close mean" lookup).
- `scripts/check_phase9_close_invariants.sh` is retained as a
  permanent regression check (if any future commit removes a
  facade type, re-introduces a SKIP-WIN64-* arm, etc, the check
  FAILs).

## Related

- ADR-0104 (Phase 9 honest-accounting reframe — this rule's
  motivating META decision).
- ADR-0105 (JIT-prologue stack-probe — closes I1's D-162).
- ADR-0106 (multi-result ABI redesign — closes I1's D-164).
- ADR-0078 (SKIP taxonomy — SKIP-WIN64-* reclassified per ADR-0104
  Revision history row 2026-05-22).
- ADR-0102 (§9.12-F exit reframe — per-row predicate cited by I5).
- ADR-0025 (Zig library facade — I3 minimum subset).
- `.dev/phase9_close_master.md` §6 (the canonical exit predicate
  this rule's I1-I7 enforce).
- `.claude/rules/no_workaround.md` (sibling rule on workarounds
  generally; this rule is the Phase-9-specific application).
- `.claude/rules/no_fallback_on_failure.md` (sibling on silent
  fallbacks).
