# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ⚑ windowsmini gating SUSPENDED (ADR-0174) — 2-host (Mac+ubuntu) FAST loop

win-harden-I bundle CLOSED @9d832f1d (the `pass=0` anomaly was a transient corpus state; fix = runners `exit(1)` on
missing corpus root + build.zig `test-corpus-presence` gate). `.dev/windows_gate_suspended` = `9d832f1d`;
`should_gate_windows.sh --resume` before any `main` merge / Win64-risk diff (ABI/cc/frame-layout). A13 strict-3-host
merge gate (`gate_merge.sh`) UNCHANGED. Findings: [`windows_hardening_findings.md`](windows_hardening_findings.md).
Loop NEVER idles; **No release/tag EVER** (ADR-0156).

## ✅ E2 CLOSED — a REAL Rust wasm32-wasip2 component RUNS via zwasm (@96e1ccce)

A genuine `rustc --target wasm32-wasip2` component (wit-bindgen shim/fixup, full wasi:cli) prints e2e + exit 0.
Delivered: **ADR-0175** general instance-graph engine @8eab1703 · **D-310** imported-host-funcs-funcref-able @4e802881
+ component memory fix @96e1ccce. Fixture `test/component/wasi_p2_hello_rust.wasm` (78 KB) + e2e + dogfood.

**E1 DONE** (plan §Phase E): `test/spec/component_model_assert_runner.zig` — a Component-Model spec corpus runner
that decodes+instantiates+invokes over `test/spec/component-model-assert/`, built against a component-ENABLED
`zwasm` module (`core_comp` in build.zig), wired into `test-all`. First corpus = greet (string→string) + adder graph
(cross-module i32): 4 pass, 0 skip. ADR-0174 lesson: missing corpus root = hard `exit(1)`. Fixtures reuse `test/component/`.

**NEXT = E3-CM-validation bundle (OPEN; see `## Active bundle`)**: component-model conformance via a structural-first
**component validator** (ADR-0176) driven by the official `WebAssembly/component-model/test/wasm-tools` `assert_invalid`
corpus (365 + 17 malformed). `src/feature/component/validate.zig` runs after `decodeTypeInfo`, before instantiate, at
all 3 host entry points. **Rule 1 (type-index bounds) DONE** — runner gained `assert_invalid`/`assert_malformed`
directives; fixture `type_index_oob/oob.wasm` (authored via `wasm-tools parse`, no-validate encode). Each further rule
= 1 chunk + ≥1 corpus-derived fixture; deferred deep-type cases stay truthful `skip-impl` (NOT blanket-skip — D-301).
E2 remainder (Go/tinygo cross-toolchain proof) is opportunistic — toolchain-gated, not the blocker.
**Resume routing**: `## Active bundle` (1b) supersedes the plan's E3 row; `/continue` resumes the next validation rule.

## Active bundle

- **Bundle-ID**: E3-CM-validation (ADR-0176)
- **Cycles-remaining**: ~4 — rules in frequency order: ✅1 type-index bounds · 2 names (kebab-case + valid
  extern/import names) · 3 outer-alias count + alias-target existence · 4 export-type-validity / index-space bounds.
- **Continuity-memo**: `validate.zig` walks the decoded `TypeInfo` (no re-parse) post-`decodeTypeInfo`, pre-instantiate,
  at instantiate/instantiateGraph/runWasiP2Main. Runner `assert_invalid`/`assert_malformed` directives decode→typeinfo
  →validate, expect error. Fixtures: hand-author invalid `.wat` (numeric OOB / bad names) → `wasm-tools parse` (encodes
  WITHOUT validating) → commit `.wasm` under `test/spec/component-model-assert/<rule>/`. Deferred deep-type = truthful `skip-impl`.
- **Exit-condition**: structural rule set (1–4) landed, each with ≥1 corpus-derived `assert_invalid` fixture passing in
  `test-component-spec`; deep canonical-ABI / subtyping cases enumerated as `skip-impl` with specific reasons.

## Active campaign — Component Model + WASI Preview 2 (ADR-0170, user-directed 2026-06-07)

**Goal**: full **wasmtime-equivalent** CM + WASI-P2, the zwasm-v2 way (spec/test-referenced NOT copied;
philosophy-maintained; proven by Rust+Go sample components). Decision + rationale: **ADR-0170**.

- **DRIVER = [`.dev/component_model_plan.md`](component_model_plan.md)** — its **§Work sequence** is authoritative
  and SUPERSEDES ROADMAP §17 ordering for this campaign (close-plan-override; Resume routes here, not to a §9 row).
  Follow the first unchecked chunk; each chunk recipe = goal · files · refs · red test · exit.
- **Step 0 survey is DONE** — do NOT re-survey. Read `.dev/component_model_survey.md` (architecture, 4 hard pieces,
  module breakdown) + the plan's "Reference chains" (spec `~/Documents/OSS/WebAssembly/component-model/`; v1
  textbook `~/Documents/MyProducts/zwasm/src/{component,wit,wit_parser,canon_abi}.zig`; wasmtime/wasm-tools refs).
- **Tier 0 (A1–A4) + Tier-1 (B1–B6) COMPLETE — "COMPONENT MODEL WORKS".** decode/types/wit (A1–A4) · canon value
  machinery (B1–B5: flat-scalar/enum/flags/string/list/record/variant over guest memory) · **B6 single-component
  instantiate+invoke e2e** (IT-1 @20132372 instantiate+invoke · IT-2 @41e50658 flat trampoline + Value bridge · IT-3a
  @6e784d5c cabi_realloc-via-guest seam · IT-3b-1 @9024d4bb canon-section decode · IT-3b-2 @cff26592 real fixture decodes
  · **IT-3b-3 @e0e7c9f5 a REAL wasm-tools string→string component RUNS e2e** — `greet("zwasm")`⇒`"Hello, zwasm!"`).
  ADR-0171 (cabi_realloc seam) + ADR-0172 (Zone split). **Bundle CM-B6-IT CLOSED** (exit met @e0e7c9f5).
- **Discipline**: pure logic Zone 1 (`feature/component/`), orchestration Zone 3 (`api/component.zig`); component-value
  DISTINCT from `runtime.Value`; TDD; no-copy; 3-host gate; **no tag**.
- **Phase C COMPLETE (Tier-1 done): resources + multi-component linking.** C1 @11043031 (`resource_table.zig`:
  handles table, own/borrow, new/rep/drop, double-drop/use-after-drop/still-lent traps). **C2 @fc5956dc**: C2-1
  core-instance/alias decode · C2-2 export resolution (D-304 closed) · C2-3a component-instance §5 decode · C2-3b-1
  real 2-component fixture decodes · **C2-3b-2 a 2-component graph LINKS + RUNS** (`instantiateGraph`: wire A's core
  import to B's `adder` via Linker cross-module; `add-five(10)`=15, a real cross-component call). Bundle CM-C2 CLOSED.
  Name-matched-import shortcut + aggregate cross-component args → **D-305**.
- **Phase D (WASI Preview 2) — D1+D2+D3 DONE** (detail in plan §Phase D). D1 core @96edb868 (`runWasiP2Main`
  decode-drives the inner core graph; `wasi_p2_hello.wasm` prints "hello") + CLI run path @161236db (`zwasm run`
  dogfooded) + ADR-0173 (host-ctx seam). D2 @85bcb5a5 — resource-modeled fs (descriptor RT, get-directories list via
  reentrant cabi_realloc, open-at/write); classified-by-interface wiring D-306.
- **Phase D3 DONE** (hand-authored-fixture native host; detail in plan §Phase D3). D3-1 exit · D3-2/3 clocks · D3-4
  random · D3-5 stdin · **D3-6 fs descriptor** @43909eba (read/sync/stat/get-type + flush; **D-307 DISCHARGED**
  @beb887c6) · **D3-7 wasi:io/poll** @3a128a01 (pollable + subscribe + ready/block/poll). **D-309 DONE** @ccdee2fa —
  WASI-P2 trampolines extracted to `api/component_wasi_p2.zig` (component.zig 1922→1250).
- **NOW = E3-CM-validation bundle** (component validator; rule 1 type-index bounds @cfdb07be; D-308 edge case @82d63d27). Deferred: D3-8 sockets (spike-first).
  Cross-component aggregate → D-305. **D-308 DISCHARGED @82d63d27** — unknown-wasi-import errors cleanly (no signal);
  ADR-0175 engine's per-instance cleanup is sound; adversarial guard `wasi_p2_unknown_import.wasm` (E3 edge case).

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168). DONE+3-host: atomics @9eb84833 · wide-arith @231d4536 ·
  custom-page-sizes @cd0de2dd · relaxed-SIMD @08342ec5 (+official corpus @8ef2e752, 13420 pass arm64+x86). Wasm-3.0
  core 100%-spec COMPLETE. Last SHA **cfdb07be** (E3-CM-validation rule 1: type-index bounds; test-all+lint green; ubuntu OK @1e31317a; windows susp @9d832f1d).
- **Atomics fully conformant @e6f3b0c0** — official corpus **294 pass, 0 SKIPPED** (D-301), incl. the JIT
  unaligned-atomic-trap fix D-303 (code-14 `unaligned_atomic_fixups` both arches, @5b0db8e1, 3-host).
- **ALL bounded debt CLEARED**: ✅ D-301 · ✅ D-303 · ✅ D-231 (cross-x86 DCE gate wired @aac4fe2f) · ✅ D-302
  (branch-hint custom-section verified @dcc8d71c) · ✅ **D-279 DISCHARGED @c287d39c**.
- Debt ledger **52 entries** (D-307/D-309/D-310/D-308 discharged). `now` = D-299 only
  (env-constrained). **Correctly DEFERRED (do NOT clear)**: D-209
  (hot-path), D-259 (W54-ABI-risk), D-300 stack-switching (Phase-3 unstable), D-299 (x86_64 W^X).
- 完成形 v0.1 surface COMPLETE: CLI D-295 (~85%, intentionally lean) · C-API ZERO gaps (293/293) · Zig-API
  COMPLETE · memory-safety all-areas SOUND (D-296/D-297). Dogfooding D-264 DONE (cw v1 side).

**Blocked / parked**: 31 blocked-by (call_ref §10.R / D-177 / D-178 / future proposals). **D-290** = 3 distillers
direction-gated. 

## Step 0.7 (next resume) — hosts were SHUT DOWN; first windows run = the campaign

- **All 3 hosts powered off** after @87635409 (user). `/tmp/ubuntu.log` last verdict was OK @87635409;
  `/tmp/win.log` shows the **pass=0 spec-assert anomaly** (see NEW DIRECTIVE #1 — the campaign's first lead). On a
  fresh boot, `/tmp/*.log` are stale — re-kick both as the first campaign step; the windows run IS the investigation.
- **ubuntu**: re-kicked each turn (D6). Red → auto-revert (D3; first-resume exception). **windows**: NOT auto-revert
  (D7); the campaign is actively hunting Win64 bugs, so a red windows is the SIGNAL, not a flake-to-dismiss.
- **Gate note**: realworld `OK` can MASK a broken spec-assert phase (the pass=0 anomaly). EXPECTED non-failures:
  `zig-host-hello` exit-42, `--__selftest-crash` exit-70, sha256 `verify: FAIL` (fixture-wrong-constant FALSE lead).

## Key refs

- **ADR-0170** (CM full campaign) + [`component_model_plan.md`](component_model_plan.md) +
  [`component_model_survey.md`](component_model_survey.md) — the active campaign.
- **ADR-0174** (windowsmini hardening → gate suspension; switch = `scripts/should_gate_windows.sh --suspend|--resume`,
  sentinel `.dev/windows_gate_suspended`) · **ADR-0156** (no release) · **ADR-0076** (3-host cadence) · **ADR-0168**
  (Phase 17) · **ADR-0023** (subsystem slots) · `no_copy_from_v1` · `single_slot_dual_meaning` · `.dev/proposal_watch.md`.
