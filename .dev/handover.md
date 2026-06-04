# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (Public release v0.1.0 🔒) IN-PROGRESS.** Phases 0–15 DONE. Last commit: ROADMAP §15.P [x]
  + widget 15→DONE / 16→IN-PROGRESS + §16 table opened.
- **Phase 15 CLOSED** (§15.P parity-vs-v1 measured + the D-265 register-homing rework campaign closed).
  §15.1 GC reclamation DONE (`be4357be`). §15.2/15.3 regalloc-axis perf folded — **ADR-0149/0150 Revision
  landed** (the "~0 headroom" claim measured the wrong proxy; real headroom existed on the loop-local
  hot path, recovered by D-265). §15.4 SIMD DONE (`1029e5b4`). §15.5 win64 trampoline DONE (`510ffce9`).
  §15.6 ClojureWasm CI ⏸ DEFERRED (ADR-0152 → D-264). §15.P close `[x]` this cycle.
- **D-265 rework campaign (ADR-0153) DONE — all 5 phases.** Register-homed i32/i64 locals on BOTH backends
  (arm64 `a64c72a1`/`5d1dd221`, x86_64 `e8b7ad10`). **ROI met**: arm64 `w45_addi` 2.30×→**0.97×**; x86_64
  (Rosetta) reads-i/control differential 2.4×→**1.0×** (loop-local reload penalty eliminated). **Verified
  3-host**: Mac arm64 + Rosetta x86_64-macos + **ubuntu x86_64-linux test-all GREEN** (`33fe020a`, spec
  25437/0, fac-i64/recursive correct = the cases the first try `f31affa1` miscompiled). Findings +
  post-rework table: `bench/results/s15p_parity_vs_v1.md` (doc-state RESOLVED).

## NEXT (autonomous)

- **§16.1 — write `docs/migration_v1_to_v2.md`** (v1→v2 migration guide). v1-ABI dropped (§1.1/§3.2);
  cover CLI / C-API / WASI / Zig-embed (ADR-0025 §D) deltas + the v1-parity line (§1.2). Then §16.2
  CHANGELOG, §16.3 README, §16.4 `docs/reference/` API, §16.5 `docs/tutorial/`. These are autonomous
  docs work — chain them.
- **§16.P is the 🔒 RELEASE GATE — user-gated.** Cutting the `v0.1.0` GitHub tag + publishing binaries is
  outward-facing/irreversible: the loop prepares §16.1–5, then STOPS and surfaces to the user before
  tagging. Do NOT self-tag/publish.

## Step 0.7 (next resume)

**No pending ubuntu verification** — the D-265 campaign's last emit commit `e8b7ad10` is ubuntu-test-all
GREEN (`/tmp/ubuntu.log`, HEAD=33fe020a). Phase 16 is docs-only → no per-arch emit, no ubuntu kick needed.
**D-262 process rule still stands**: any NEW per-arch emit chunk (should one arise) → `run_remote_ubuntu
test-all` (NOT narrow `test`) before discharge (cross-compile ≠ cross-run; lesson `cross-compile-is-not-cross-run`).
**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini exec = phase boundary.

## Deferred / open debt

- **STRUCTURAL RISKS (hub: lesson `session-retrospective-structural-risks`)** — **D-261** (NOW, top stakes)
  GC-on-JIT conservative rooting has NO adversarial test → latent UAF (+ D-258 JIT GC trigger). **D-210**
  (blocked-by) cohort root fix recurring at 4 seams (D-142/206/210/245) — decide root-vs-patch. (D-262/D-263
  discharged: D-262 process rule internalized; D-263 parity now MEASURED + the regression FIXED via D-265.)
- **D-266** (note) native-x86_64 absolute ROI vs v1 unmeasured (confirmation-only; mechanism proven fixed +
  ubuntu green). **D-258** (NOW) JIT-trampoline GC collect trigger. **D-211** (blocked-by) precise GcRootMap.
  **D-259** (note) spillBytes footprint. **D-257** 10 lesson `Citing` backfill. **D-255** C-API WASI io.
  **D-254** rust 3-OS. **D-253** §13.2 host_info. **D-251** WASI in AOT. **D-249** win bench. **D-238** x86_64
  EH thunk. D-234/237/229/231/204/209/213.

## Key refs

- ROADMAP §16 task table (16.1 migration → 16.2 CHANGELOG → 16.3 README → 16.4 API ref → 16.5 tutorial →
  16.P 🔒 release gate). Phase Status widget (15 DONE / 16 IN-PROGRESS). ADR-0025 (stable Zig surface +
  §D migration-guide chain); ADR-0153 (D-265 rework campaign); ADR-0149/0150 (perf folds + 2026-06-04
  Revision); ADR-0151 (W45 folded). §1.1/§1.2/§3.2 (v0.1.0 parity line + v1-ABI drop).
