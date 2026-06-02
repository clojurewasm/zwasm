# Wasm 1.0/2.0/3.0 level-separation INTEGRITY audit — wiring / reference chain

> **Doc-state**: ACTIVE
>
> PREP only (user directive 2026-06-02). The FULL audit runs in a fresh deep
> session. This is the wiring + the confirmed finding + the checklist, so that
> session executes in one pass. Distinct axis from `phase10_scope_reassessment.md`
> (that = §10 exit-criteria / Phase-14 deferral; THIS = does level-specific code
> actually stay confined to its level, or is it "half convention-reliant"?).

## The concern (confirmed, not hypothetical)

The project's stance (ROADMAP §4.6 / A12, ADR-0073): build flag `-Dwasm=v1_0|v2_0|v3_0`
selects a level; higher-level ops are **comptime-DCE'd** so a v1_0 build has *no
binary symbol* for 2.0/3.0 handlers; **no pervasive `if (gc_enabled)`** in
parser/validate/interp/emit — separation is by per-feature **directory + dispatch
registration**, gated by `wasm_level` metadata. The existing
`dispatch_consistency_audit` enforces the *shape* of this (counts + metadata + DCE
sampling). **But the DCE + the audit both assume level logic lives in per-op
files.** Where 3.0 logic is **inlined into the shared `mvp.zig` dispatch shell**,
it is neither per-op-DCE'd nor body-inspected → the separation there is *runtime-
validator-only*, i.e. exactly the "half規約頼み" the user flagged.

## Reference chain (read in order; file:line)

1. **Level mechanism / DCE**: `build.zig:21` (`-Dwasm=` option) → `build.zig:77`
   (`addOption(WasmLevel,"wasm_level")`) → `src/ir/dispatch_collector.zig:61`
   (per-op `pub const wasm_level`) → `:107-127` `enabledByBuild()` comptime filter
   (level > target → not instantiated → no symbol). **ADR-0073**
   (`.dev/decisions/0073_build_option_dce_substrate.md:54-65`): "in a `-Dwasm=v1_0`
   build, handlers … for Wasm 2.0+ are not reached at comptime → absent from the
   binary." ← the claim to TEST against the mvp inline leaks.
2. **Existing audit scope**: `.claude/skills/dispatch_consistency_audit/SKILL.md:19-32`
   (4 axes: tag-count parity, 5-axis handler completeness, `wasm_level` consistency,
   DCE sampling). `:101-113` axis-2 greps for `.<axis> =` presence — **does NOT parse
   handler bodies.** BLIND SPOT (below).
3. **The leaks (inventory)** in `src/interp/mvp.zig` (the shared MVP shell — itself
   has NO `wasm_level` tag):
   - `br_on_cast` / `br_on_cast_fail` (registered :92-93) → body `:342` calls
     `ref_test_ops.gcRefMatchesNonNull()` (3.0 GC RTT). Op nominal level `.v3_0`
     (`src/instruction/wasm_3_0/br_on_cast.zig:20`) — but the handler lives in mvp.
   - `call_indirect` (registered :96) → body `:445-446` calls
     `ref_test_ops.concreteReaches()` (Wasm 3.0 §3.3.5.5 subtype). **Op nominal
     level `.v1_0`** (`src/instruction/wasm_1_0/call_indirect.zig:13`) — a 1.0 op
     with 3.0 logic inlined. (gti-gated at runtime, so non-GC behaviour is correct,
     but the 3.0 code is compiled in.)
4. **Gating reality**: `src/interp/mvp.zig:64-125` `register()` registers ALL ops
   **unconditionally** (no `if (build_options.wasm_level)`). Comment at `:98-104`
   states the gate is at LOWERING (`src/ir/feature_level_check.zig` `v3_op_tags`),
   not registration — "unconditional registration here is harmless." → **separation
   is lowering/validator-enforced, NOT registration/DCE-enforced for mvp handlers.**
5. **Stated policy**: ROADMAP `:817-842` (§4.6 source-separation A12), `:156` (A12),
   `:1308` (§9.12-B: `test-all` green for all 6 `-Dwasm` combos = the DCE exit).

## BLIND SPOT (one sentence)

`dispatch_consistency_audit` verifies *infrastructure consistency* (count parity +
`wasm_level` tagging + symbol-presence sampling); it does NOT verify *code
containment* — a `.v1_0` op whose handler body inlines 3.0 GC logic (call_indirect →
concreteReaches) passes every axis, yet violates level separation, and because mvp
handlers register unconditionally the 3.0 code is in the v1_0 binary (DCE only drops
per-op-FILE handlers, not mvp-shell inline calls).

## Audit checklist (deep session)

1. **Body-leak inventory**: grep `src/interp/mvp.zig` (and any shared shell:
   `interp/dispatch.zig`, validator, emit cores) for `ref_test_ops` / `gc/` /
   `wasm_3_0/` / `gti` / `concreteReaches` / `gcRefMatches`; per site name the op +
   its declared `wasm_level`; flag any sub-v3 op calling 3.0 logic.
2. **DCE truth test**: build `-Dwasm=v1_0 -Dengine=interp`; `nm` the binary for
   `gcRefMatches*` / `concreteReaches*` — present? If yes, ADR-0073's "absent from
   binary" claim is FALSE for mvp-inline 3.0 logic → decide fix vs amend-claim.
3. **Confirm policy-vs-code**: does ROADMAP §9.12-B's "all 6 `-Dwasm` combos green"
   actually exercise these paths, or does it only check compile+run, not symbol
   containment? (i.e. is there a `check_build_dce.sh` that `nm`-greps?)
4. **Extend the audit**: can `dispatch_consistency_audit` gain a body-containment
   check (grep each per-op handler + the mvp-shell handlers for cross-level imports
   vs declared level)? Or is a new lint needed (this is the structural fix).
5. **Decide the leaks' disposition**: extract br_on_cast / call_indirect-subtype
   into per-op files (so DCE + the audit cover them), OR explicitly bless the
   mvp-shell-inline pattern + amend ADR-0073/A12 to describe it. (ADR-grade.)

## Decision points for the next session

1. Is the mvp-shell handler an *accepted* exception to "level logic in per-op files
   + DCE" (then ADR-0073/A12 must say so + the audit must whitelist it), or a leak to
   refactor into per-op files? (br_on_cast was always there; call_indirect-subtype is
   new — 2 different verdicts possible.)
2. Does `dispatch_consistency_audit` need a body-containment axis (the structural
   guard against future inline leaks)? Where + how (grep-based vs treesit).
3. Does ADR-0073's "absent from binary" wording need narrowing to "per-op-file
   handlers" (honest), pending the `nm` truth-test result.
