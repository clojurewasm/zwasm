# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ⚑ NEW DIRECTIVE — windowsmini hardening THEN gate suspension (user-directed 2026-06-07, ADR-0174)

**Read first. This supersedes the routine loop priority.** The user is shutting down all 3 hosts after this commit; the
windowsmini verification load was conflicting with their separate ClojureWasmFromScratch work. **Two-phase plan:**

1. **FIRST — windowsmini-hardening campaign (immediate priority next session).** Run windowsmini intensively
   (low/zero batch threshold) and get it **fully, verifiably green** — real spec-assert pass counts matching ubuntu,
   not a MATCH-only `OK`. **First lead** (captured @87635409, /tmp/win.log): windows `[run_remote_windows] OK` but the
   spec-assert phase shows **`pass=0` across EVERY category** (assert_return pass=0/fail=0; assert_invalid
   pass=0/fail=194; some trap/malformed fails) while ubuntunote on the SAME commit passes all with real counts ⇒ a
   **windows-side spec-runner execution/reporting failure masked by the OK verdict** (the verdict keys off realworld
   MATCH only). Root-cause this FIRST (investigation-discipline hypothesis list); then any remaining real Win64
   divergence. Open a campaign/bundle for it.
2. **THEN — suspend windows gating** so Mac+ubuntu iterate FAST: `bash scripts/should_gate_windows.sh --suspend`
   (writes `.dev/windows_gate_suspended`; the gate then always defers → **2-host gate Mac+ubuntu**). `--resume` before
   any `main` merge / Win64-risk diff / on user request. A13 strict-3-host merge gate (`gate_merge.sh`) is UNCHANGED.

**Then** resume normal loop: the CM+WASI-P2 campaign below (Phase D3/E). The loop NEVER idles; **No release/tag EVER**
(ADR-0156). D-279 stays discharged (lesson `2026-06-07-always-on-debug-dump-was-the-heisenbug`) — but note the pass=0
anomaly above is a DISTINCT, NEW windows signal, not a D-279 reopen.

## Active bundle — windowsmini-hardening (ADR-0174 Phase I)

- **Bundle-ID**: win-harden-I (spec-assert pass=0 root-cause)
- **Cycles-remaining**: ~2 (confirm mechanism → fix → re-verify green)
- **Continuity-memo**: hosts ARE up (probed @f8bcc040; handover's "powered off" was stale). ubuntu baseline GREEN with
  real counts (non_simd 25437, simd 13420, 1.0 212, threads 294). Findings + mechanism map + ubuntu SKIP histogram in
  [`windows_hardening_findings.md`](windows_hardening_findings.md). Prime hypothesis = `callJitOrTrap` VEH
  false-positive → `SKIP-START-TRAP` whole-module skip (ubuntu skips 0). Missing-corpus mask RULED OUT (corpus present
  on win). Awaiting empirical win test-all summary (in-flight @f8bcc040, /tmp/win.log) to confirm symptom.
- **Exit-condition**: windows `test-all` spec-assert summaries show real pass counts matching ubuntu (no `pass=0`, no
  mass `SKIP-START-TRAP`); THEN ADR-0174 phase 2 (`should_gate_windows.sh --suspend`).

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
- **Phase D (WASI Preview 2) IN PROGRESS** (plan doc §Phase D). **D1 CORE DONE — a real WASI-P2 component RUNS via
  zwasm.** D1-1 @b35a683e (`wasi/adapter.zig` P2→P1 name-map). D1-2 trampolines @2d099ff1 (host-ctx seam `Caller.data`
  + `Linker.defineFuncCtx`, ADR-0173; `WasiP2Ctx` + p2 output-stream trampolines onto P1 `fd.writeSlice`). D1-2c
  @27eb59b8 (unified core-func index-space `CoreFuncDef` — `resolveCoreFuncExport` now indexes lowers+resource+aliases,
  not aliases alone). **D1-2 EXIT @96edb868** — `runWasiP2Main` decode-drives the inner core graph ($libc + $M, wasi
  imports → trampolines, libc memory cross-instance) and `wasi_p2_hello.wasm` prints "hello\n" to captured stdout.
- **CLI run path DONE @161236db** — `zwasm run <component.wasm>` routes a component-layer module to `runComponentWasi`
  → `runWasiP2Main`; `zwasm run test/component/wasi_p2_hello.wasm` prints "hello" + exits 0 (dogfooded). D1 fully done.
- **Phase D2 DONE — bundle CM-D2-fs CLOSED @85bcb5a5** (plan §Phase D [x]). Resource-modeled P2: classified host
  wiring (D-306 @dde03160, by COMPONENT interface not core name; proof `wasi_p2_hello_renamed.wasm`) · stderr @1f5474d5
  · **descriptor resource** (`WasiP2Ctx.resources` keyed by RT id) write/drop @b766c583 · **get-directories @e9d05999**
  (list return-area built via the guest's `cabi_realloc` called from a trampoline — nested invoke, lesson
  `2026-06-07-engine-invoke-is-reentrant-stack-disciplined`) · **open-at @a8264fb4** · generic resource-drop @75d79a6c.
  **EXIT @85bcb5a5**: `wasi_p2_fs.wasm` runs e2e through `runWasiP2Main` (get-directories → open-at "out.txt" → write
  "DATA42" → drop), file content asserted. Fixture uses minimal WIT flags/enum (zwasm classifies by interface+core-sig,
  so it runs; full real-WASI-type conformance is the Phase E2 toolchain proof).
- **NEXT = Phase D3** (plan §Phase D3): clocks/random/exit/stdin free-func trampolines + full fs/poll; sockets last
  (spike first). P1→P2 error-code result mapping = **D-307**. OR Phase E (conformance corpus + Rust/Go sample proof).
  Cross-component aggregate args → D-305.

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168). DONE+3-host: atomics @9eb84833 · wide-arith @231d4536 ·
  custom-page-sizes @cd0de2dd · relaxed-SIMD @08342ec5 (+official corpus @8ef2e752, 13420 pass arm64+x86). Wasm-3.0
  core 100%-spec COMPLETE. Last SHA **85bcb5a5** (WASI-P2 fs component runs e2e — CM-D2-fs bundle EXIT).
- **Atomics fully conformant @e6f3b0c0** — official corpus **294 pass, 0 SKIPPED** (D-301), incl. the JIT
  unaligned-atomic-trap fix D-303 (code-14 `unaligned_atomic_fixups` both arches, @5b0db8e1, 3-host).
- **ALL bounded debt CLEARED**: ✅ D-301 · ✅ D-303 · ✅ D-231 (cross-x86 DCE gate wired @aac4fe2f) · ✅ D-302
  (branch-hint custom-section verified @dcc8d71c) · ✅ **D-279 DISCHARGED @c287d39c**.
- Debt ledger **53 entries**. `now` = D-299 only (env-constrained). **Correctly DEFERRED (do NOT clear)**: D-209
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
