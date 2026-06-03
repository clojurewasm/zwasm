# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 15 (Performance parity with v1 + ClojureWasm) IN-PROGRESS.** Phase 14 (CI matrix) DONE
  (ADR-0145). Phase 13 (C API) DONE (ADR-0144). Phase 12 (AOT) DONE.
- **Phase 14 recap**: CI workflows (`pr`/`bench`/`bench_baseline`/`nightly`.yml — all workflow_dispatch,
  actionlint-clean, §14.5 CI-second-line) + fuzz infra (`test/fuzz/` parse/validate/instantiate crash-harness
  in test-all + the nightly smith campaign + proposal-watch + spec-bump legs). §14.P **re-scoped past D-245
  win64** (ADR-0145, same as §13.P/ADR-0144): deliverables 3-host-green (test-fuzz `0 crashes` on Mac+ubuntu+win),
  windows sole-failure = the D-245 carry. audit_scaffolding 0-block (`private/audit-2026-06-04-p14close.md`).

## Next task (autonomous)

**§15.1 — GC reclamation + precise rooting** (ex-§11.4/D-211, ADR-0135; co-defines `zir.GcRootMap` with §12.5
AOT stack-map, ADR-0141). The Phase-10 collector is non-moving + β-no-reclaim (mark-sweep wired; dead bytes leak,
`collector_mark_sweep.zig:214`). Add: free-list reuse / compaction (ADR-0115 §10) + a `GcRootMap` stack-map root
walker (currently empty placeholder) + conservative native-stack scan (ADR-0128 §2). Mac-local-verifiable. Step
0: survey the collector + `GcRootMap` placeholder + ADR-0115/0128/0135. **Then** §15.2 coalescer → §15.3 class-aware
allocator → §15.4 SIMD ports → **§15.5 D-245 win64** (recurring windows blocker; hard/remote — a deliberate
session, or user-prioritized) → §15.6 ClojureWasm CI. (D-257 ADR-backfill half done `2893ab5e`; lesson-Citing
half now `soon`, not blocking — cycle-refs aren't SHA-recoverable.)

## Step 0.7 (next resume)

This turn: D-257 ADR SHA-backfill (9 rows, `2893ab5e`) + D-257 → soon — DOCS only, no code → no ubuntu kick
(HEAD code `011dca7e` ubuntu-verified). **windowsmini reconcile (Phase-14 close) = `[run_remote_windows] OK`
GREEN** (seed `0x75fe1ff4` dodged D-245; the only `failed command: …--listen=-` lines are benign unit-test-
isolation noise, lesson `gate-tail-vs-exit-code`). §14 close fully verified 3-host. Next code change → ubuntu kick.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **D-257** (NOW) 20-marker `<backfill>` cohort — discharge this resume. **D-245** win64 host→JIT = §15.5
  (windows-CI/bench-green; hard remote asm). **D-255** C-API WASI io-infra (ADR-0143). **D-254** rust 3-OS
  (ADR-0142). **D-253** §13.2 host_info (cap). **D-251** WASI in AOT. **D-249** win bench timing (ADR-0137).
  **D-246** arm64 dot/extmul = §15.4. **D-238** x86_64 EH thunk. D-210/D-234/D-237/D-229/D-231/D-204/D-209/D-213.

## Key refs

- ROADMAP §15 task table (just expanded; 15.1 GC … 15.5 D-245 … 15.6 ClojureWasm). Phase Status widget
  (14 DONE / 15 IN-PROGRESS). ADR-0145 (§14.P close, re-scope-past-D-245); ADR-0135/0115/0128 (GC); ADR-0141 (§12.5).
