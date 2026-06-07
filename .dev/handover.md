# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## NEVER-IDLE PROTOCOL (read first — user-directed 2026-06-06)

The loop **NEVER idles.** v0.2/v0.3 feature work is UNBLOCKED ("AIが思いのほか早いのでどんどんやろう"). **No
release/tag EVER** (ADR-0156; user reconfirmed "タグは切らない"). **Work priority each resume:**
1. **THE ACTIVE CAMPAIGN below** (Component Model + WASI-P2) — the primary forward track. Drive it via the plan doc.
2. Between chunks OR campaign-gated → sweep `.dev/remaining_sweep.md` / 完成形 polish — never idle.
3. **D-279 + similar NEVER "left alone"** — verify the remote signal every Step 0.7 (D-279 is now root-caused +
   mitigated; just confirm clean Win64 runs build its discharge streak).

## Active campaign — Component Model + WASI Preview 2 (ADR-0170, user-directed 2026-06-07)

**Goal**: full **wasmtime-equivalent** CM + WASI-P2, the zwasm-v2 way (spec/test-referenced NOT copied;
philosophy-maintained; proven by Rust+Go sample components). Decision + rationale: **ADR-0170**.

- **DRIVER = [`.dev/component_model_plan.md`](component_model_plan.md)** — its **§Work sequence** is authoritative
  and SUPERSEDES ROADMAP §17 ordering for this campaign (close-plan-override; Resume routes here, not to a §9 row).
  Follow the first unchecked chunk; each chunk recipe = goal · files · refs · red test · exit.
- **Step 0 survey is DONE** — do NOT re-survey. Read `.dev/component_model_survey.md` (architecture, 4 hard pieces,
  module breakdown) + the plan's "Reference chains" (spec `~/Documents/OSS/WebAssembly/component-model/`; v1
  textbook `~/Documents/MyProducts/zwasm/src/{component,wit,wit_parser,canon_abi}.zig`; wasmtime/wasm-tools refs).
- **Tier 0 (A1–A4) + Tier-1 canon value machinery (B1–B5) COMPLETE** (per-chunk SHAs + recipes in the plan doc's `[x]`
  rows): decode/types/wit (A1–A4) · canon flat-scalar (B1, ADR-0171) · enum/flags+size/align (B2) · utf8 string (B3) ·
  recursive list/record store/load (B4) · variant/option/result/tuple decode + canon variant (B5). ubuntu GREEN through
  B4; the canon module lifts/lowers/stores/loads every Tier-1 value type over guest memory via the injected realloc cb.
- **Discipline**: pure component logic = Zone 1 (`feature/component/`), host orchestration = **Zone 3** (`api/component.zig`,
  ADR-0172); NO core-VM change (drive `Engine`/`Instance` facade as black box); component-value DISTINCT from
  `runtime.Value`; TDD + boundary fixtures + spec-citation; no-copy; 3-host gate; no tag.

## Active bundle

- **Bundle-ID**: CM-B6-IT (single-component instantiate + invoke e2e)
- **Cycles-remaining**: ~3 (IT-3b grew — it needs canon-section decode + full export path + a real fixture)
- **IT-1 @20132372** (instantiate + invoke `run()->i32=42`) · **IT-2 @41e50658** (canon flat trampoline `invokeFlat`;
  `runtime.Value`↔`zwasm.Value` bridge proven) · **IT-3a @6e784d5c** (cabi_realloc-via-guest: `canonContext()` +
  `reallocViaGuest` invokes the guest's `cabi_realloc` export; a host string lowers THROUGH the guest allocator into
  guest memory + lifts back — ADR-0171's core seam proven e2e with a hand-crafted bump-allocator module).
- **Continuity-memo**: NEXT = IT-3b, the EXIT, now scoped into sub-steps: **(b-1)** decode the component `canon`
  section (id 8) — `canon ::= 0x00 0x00 core:funcidx opts typeidx` (canon lift) + `opts` (string-encoding / memory /
  realloc / post-return) [`Binary.md` §canon]; deferred since A2, add to `decode.zig`/`types.zig`. **(b-2)** the full
  component-export invoke path: export → its canon-lift → underlying core func + string-encoding opt + the
  cabi_realloc-via-guest CanonContext; lift host string args → lower into guest → invoke; the string RESULT (2 flat
  values > MAX_FLAT_RESULTS=1) returns via an INDIRECT return-area pointer (read `CanonicalABI.md` `canon_lift` /
  `flatten_functype` / `lower_heap`); also handle memory-grow invalidating the captured slice (re-fetch after realloc).
  **(b-3)** a REAL string→string fixture via `nix develop .#gen` (cargo-component / wasm-tools, Mac host) + the exit
  assertion. CHECK the gen toolchain availability first (extended_challenge Step 1).
- **Exit-condition**: a string→string component runs via `api/component.zig` and returns the expected string.

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168). DONE+3-host: atomics @9eb84833 · wide-arith @231d4536 ·
  custom-page-sizes @cd0de2dd · relaxed-SIMD @08342ec5 (+official corpus @8ef2e752, 13420 pass arm64+x86). Wasm-3.0
  core 100%-spec COMPLETE. Last SHA **8c22f160** (then this session's CM-campaign scaffolding commits).
- **Atomics fully conformant @e6f3b0c0** — official corpus **294 pass, 0 SKIPPED** (D-301), incl. the JIT
  unaligned-atomic-trap fix D-303 (code-14 `unaligned_atomic_fixups` both arches, @5b0db8e1, 3-host).
- **ALL bounded debt CLEARED**: ✅ D-301 · ✅ D-303 · ✅ D-231 (cross-x86 DCE gate wired @aac4fe2f) · ✅ D-302
  (branch-hint custom-section verified @dcc8d71c) · ✅ **D-279 ROOT-CAUSED** (see history below).
- Debt ledger **52 entries**. `now` = D-299 only (env-constrained). **Correctly DEFERRED (do NOT clear)**: D-209
  (hot-path), D-259 (W54-ABI-risk), D-300 stack-switching (Phase-3 unstable), D-299 (x86_64 W^X).
- 完成形 v0.1 surface COMPLETE: CLI D-295 (~85%, intentionally lean) · C-API ZERO gaps (293/293) · Zig-API
  COMPLETE · memory-safety all-areas SOUND (D-296/D-297). Dogfooding D-264 DONE (cw v1 side).

## D-279 ROOT-CAUSED (H7 CONFIRMED @cb90da90) — history

The 12-month Win64 heisenbug was **the always-on `[d-163-jit]` dump itself** — its per-func `std.debug.print` of
the full JIT byte stream floods Win64 stdout → abort (exit-3), NOT a zwasm codegen/exec bug (why ZERO VEH
diagnostics ever fired — the crash was never in wasm). Decisive A/B: dump ON @fac174b5 → 2 exes exit-3; dump
env-gated OFF @d9d525a4 → SAME exes GREEN. Mitigation landed (dump off by default, `ZWASM_DUMP_JIT=1` re-enables).
DISCHARGE: clean Win64 runs accumulate `silent` (streak=1 @e6f3b0c0; close ≥5/≥3-SHAs). Lesson
`2026-06-07-always-on-debug-dump-was-the-heisenbug`. status `note`.

**Blocked / parked**: 31 blocked-by (call_ref §10.R / D-177 / D-178 / future proposals). **D-290** = 3 distillers
direction-gated. 

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: re-kicked each turn (D6). Verify `[run_remote_ubuntu] OK`. Last GREEN @8c22f160. Red → auto-revert
  (D3; first-resume + non-code-gap exceptions).
- **windows**: BATCHED (D8). Last GREEN @cb90da90 (H7-confirmed); gate recorded @e6f3b0c0; next batch ≥12 / ABI-risk.
  Each clean run builds D-279 discharge streak. exit-3 WITHOUT the dump would re-open D-279 (not expected). NOT
  auto-revert (D7).
- **Gate note**: `OK` = green. EXPECTED non-failures: `zig-host-hello` exit-42, `--__selftest-crash` exit-70,
  sha256 `verify: FAIL` (fixture-wrong-constant FALSE lead).

## Key refs

- **ADR-0170** (CM full campaign) + [`component_model_plan.md`](component_model_plan.md) +
  [`component_model_survey.md`](component_model_survey.md) — the active campaign.
- **ADR-0156** (no release) · **ADR-0076** (3-host cadence) · **ADR-0168** (Phase 17) · **ADR-0023** (subsystem
  slots) · `no_copy_from_v1` · `single_slot_dual_meaning` · `.dev/proposal_watch.md`.
