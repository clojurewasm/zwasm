# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 13 (C API) DONE** (closed `<this turn>`, ADR-0144). **Phase 14 (CI matrix infrastructure)
  IN-PROGRESS.** Phase 12 (AOT) DONE.
- **Phase 13 recap**: full wasm-c-api surface (§13.2), conformance suite fail=0 (§13.4, in test-all),
  host examples (§13.5: c_host + zig_host 3-OS, rust_host Mac-only ADR-0142/D-254), wasi.h re-scoped
  honest (§13.3: inherit_argv/env/preopen_dir deferred, ADR-0143/D-255). Deferred: D-253 (host_info/
  as_ref, cap-blocked).
- **§13.P close (ADR-0144)**: audit_scaffolding **0 block** (`private/audit-2026-06-04-p13close.md`).
  Phase-13 deliverables verified **3-host-green** (conformance + c_host + zig_host pass on windowsmini,
  Build Summary 61/63). The 3-host reconcile was **re-scoped** to decouple Phase-13 from the SOLE
  windows failure = **D-245 win64 host→JIT SIMD-JIT flakiness** (Phase-11 JIT-ABI, seed-flaky, NOT
  Phase-13 — 0 src/engine|src/instruction diff since `0810b339`). **⚠ USER-FLAGGED carve-out**: this
  narrows the 3-host phase-close gate; D-245 win64 is elevated (see below).

## Next task (autonomous — Phase 14)

**§14.1 [x]** `2592f255` — `pr.yml` 3-OS test-all matrix (workflow_dispatch; actionlint-clean; 3 zig URLs
verified 200; reuses bench.yml install pattern). **NEXT: §14.2 — per-merge bench, 3-OS.** `bench.yml`
ALREADY exists (workflow_dispatch, mac+linux per-merge bench → `bench/results/history.yaml`). §14.2 =
either extend bench.yml to add the windows-2022 leg OR keep 2-OS + document why (windows bench is
D-245-flaky + D-249 hyperfine-timing-open). Survey bench.yml's aggregate job + D-249/D-249. Then §14.3
(nightly: fuzz + spec-bump + proposal-watch) → §14.4 (bench_baseline workflow_dispatch) → §14.5 (confirm
pre_push still works; CI second-line) → §14.P. **CI convention = manual `workflow_dispatch`** (auto-push
disabled 2026-05-25; Phase-14 §14.5 = CI-second-line). All workflows actionlint-clean before commit.

## D-245 win64 — elevated (NOT an active bundle)

The §13.P reconcile surfaced D-245's win64 host→JIT callee-saved remainder (v128/SIMD return-value
`@call` path, `entry.zig:172`). It's **seed-flaky across Phase-11/12/13 windows closes** (lucky seeds
passed). **Elevated to a windows-gate-RELIABILITY item**; full fix (win64 + return-value-capture + arg'd
trampoline, 114 helpers) is intricate remote-only JIT-ABI work → its home is §11.3 / Phase-15 SIMD-JIT,
to land before it compromises more closes. De-bundled (not autonomous-loop-suited). The §14.1 CI matrix
will keep surfacing it as a real signal.

## Step 0.7 (next resume)

This turn: Phase-13 close (ADR-0144 re-scope; D-245 elevated). DOC-ONLY this turn (ROADMAP/ADR/debt/
handover; no src change → no ubuntu kick needed; code HEAD `528d2af3` already ubuntu-verified OK).
windowsmini reconcile is flaky-red on D-245 (the elevated carry, NOT a revert trigger). Mac gate clean
at `528d2af3` (`/tmp/mac_gate_133.log`). **NOTE** (lesson `gate-tail-vs-exit-code`): `failed command:
…test --listen=-` / `…-hello.exe` next to a passing Build Summary = benign zig test-isolation noise.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec verify = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **D-245** win64 host→JIT (v128 return-value @call) — ELEVATED windows-gate-reliability; §11.3/P15 home.
- **D-255** C-API WASI inherit/preopen (io-infra; ADR-0143). **D-254** rust 3-OS (ADR-0142). **D-253**
  §13.2 host_info/as_ref (cap-blocked). **§12.5/§11.4** GC stack-map → P15. **D-251** WASI in AOT.
  **D-246** arm64 dot/extmul → P15. **D-238** x86_64 EH thunk. D-249/D-210/D-234/D-237/D-229/D-231/
  D-204/D-209/D-213 (note). Standing: 20 `<backfill>` markers (10 ADR + 10 lesson) → sweep before §14.P.

## Key refs

- ROADMAP §14 task table (just expanded); Phase Status widget (13 DONE / 14 IN-PROGRESS). ADR-0144
  (§13.P close re-scope); ADR-0142/0143 (§13 scoping). D-245 (the elevated windows carry).
