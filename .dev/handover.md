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
- **Tier 0 COMPLETE (A1–A4)**: decode @6c51c89b · types @8d70230d · wit lexer+parser @ce62e4c5 · wit resolver @04f39205.
  ubuntu+windows GREEN through Tier 0. **B1 DONE @8724f038** (ADR-0171): `canon.zig` — component `Value` (distinct from
  runtime.Value) + flat-scalar lower/lift (bool/s8..u64/f32/f64/char round-trip) + `CanonContext` with an INJECTED
  `cabi_realloc` callback (vtable; B6 wires it to the guest export). **B2 DONE @6a223a6e**: enum (0x6d) + flags (0x6e) decode in types.zig;
  canon `DespecType` + sizeOf/alignmentOf (prim 1/2/4/8, discriminant ≤256/≤65536 flips, flags ≤8/≤16 flips) + enum/
  flags lift/lower (one i32) with range/extra-bit validation; boundary tests. **B3 DONE @1234e7a6** (canon string): utf8 lower/lift
  over guest memory via the realloc callback (first coupling exercise); StringEncoding opt (utf8; utf16/latin1 → typed
  defer); OOB/invalid-utf8/MAX-len guards, bump-mock tested. **B4 DONE @cb01a10e** (canon list+record): recursive
  `CanonType` (list/record + Field) + `Value` aggregates + recursive `store`/`load` over guest memory (list = realloc
  backing + (ptr,len); record = align_to field offsets; sizeOf/alignmentOf recursive); nested string fields; lower()
  now errors NotFlatScalar for aggregates. Round-trips list<u32> / record / record+string. **NEXT = chunk B5** (canon
  variant/option/result/tuple): discriminant + payload layout (max_case_alignment), store/load + lift/lower. Red =
  option/result/variant round-trip. Then B6 = single-component instantiate+invoke e2e (wires cabi_realloc to the guest).
- **Discipline**: Zone-2 new layer, NO core-VM change (consume `runtime/instance/*` + memory + `Runtime.invoke` as
  black box); component-value type DISTINCT from `runtime.Value`; TDD + boundary fixtures + spec-citation; no-copy;
  3-host gate; no tag. Full discipline list in the plan doc.

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
