# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.1.0 is Latest** (tag `v2.1.0` @d5d685ad4, 2026-07-06 — D-475 table64-JIT;
release.yml auto-built Release + assets). v1 frozen at `v1.11.1`. The from-scratch build campaign is
COMPLETE; the autonomous `/continue` loop is RETIRED. Dev model: cut a
`develop/<slug>` branch from `main` → PR → CI `ci-required` 3-OS gate must be
green to merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over. No active campaign/bundle; no cron self-re-arm.

## Completed maintenance sweeps (history — details in the PRs / meta_audits)

- Post-v2.0.0 scaffolding campaign COMPLETE (#118 ledger reconcile · #119/#121
  E-段1+2 de-loop/ratifications: file-size ADVISORY ADR-0099, gate_merge →
  optional pre-flight, zone_check+spill_aware promoted to CI · #120 Component域
  D-502 codec/D-504 · #122 rust-host ubuntu gate D-254).
- **Batch C / D-475 table64-JIT** MERGED #127 → **v2.1.0 released** (@d5d685ad4).

## Active front — G-senior-gap (2026-07-06, /continue entry point)

Senior-runtime gap analysis (measured; report =
`.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`) opened front
**G-senior-gap** (debt D-508..D-515, `front: G-senior-gap`). Queue order:
- **G1 = D-507 COMPLETE + MERGED** (guard-page/signal bounds-check elision;
  ADR-0202). Phase 1 #131 (reservation-backed memory), phase 2 #132 (fault→trap
  handler + trap registry), phase 3 #133 (elision flip + AOT soundness guard).
  On `main` (@5c5c45f6d). **KEY RETROSPECTIVE**: the measured scalar-elision
  perf is ~NOISE (matrix ~1% / base64 ~1.5% / fib2 within stddev) — the ADR's
  "biggest tier-free lever" hypothesis is REFUTED; the 1.75–3.9x gap vs wasmtime
  is optimising-tier codegen quality (**D-513**), not bounds checks. Elision
  still shipped: correct, code-size win, and its guard-fault infra is the base
  D-509 (threads) needs. **AOT elision is DISABLED** — `compileWasmForAot`
  forces `.explicit` + `produceFromCompiledWasm` hard-refuses elided (the
  `.cwasm`/`aot/run.zig` plain-heap path can't uphold guard soundness yet).
  Follow-ups: **D-514** (symmetric SIMD elision — x86_64 v128 handlers are
  param-threaded), **D-515** (build the D5 AOT-elision clauses + run the spec
  corpus under elision; the harnesses force `.explicit` today).
- **G3 = D-510 COMPLETE** (develop/d510-diff-fuzz PR) — the existing
  `fuzz_exec` (D-469) extended into the committed `zig build fuzz-diff` gate:
  memory-snapshot compare (silent-wrong-store class), dual JIT lanes
  (`.auto` elided vs `.explicit` inline — the ADR-0202 D-510 axis), committed
  `test/fuzz/corpus/regression/` (wazero-fuzzcases style; guard-boundary +
  memory-writing exercisers), state-divergence break after lenient outcomes.
  Validated: committed corpora 14 funcs/0 mismatch + 2008-module smith
  campaign 158 funcs/0 mismatch + fault-injection fires both MISMATCH paths.
  D-515(2) is now PARTIALLY covered (differential under elision; spec-assert
  corpora still force `.explicit`).
- **NEXT: G2 = D-508** — on-disk compilation cache (reuse .cwasm
  serialization; key = module-hash+version+arch+codegen-options; opt-in
  `--cache` CLI first; invalidation correctness > hit rate).
- Then: D-314(a) epoch-counter (recipe lives in D-314) · note-class D-509
  (threads campaign, own kickoff + ADR) · D-511/D-512 (demand-driven) ·
  **D-513 = optimising-tier DECISION row (user-gated — never self-start)**.
- Older demand-driven tail unchanged: D-444, D-506, D-502 residual, D-475
  residual (spec-harness cross-module register-table), mac/win rust-host CI.

## Operational invariants (keep using)

- **Win64 fast-repro** (~2min): cross-build `zig build test -Dtarget=x86_64-windows-gnu`
  on Mac (run-step "fails" but test.exe builds) → `scp` to windowsmini → ssh-run from
  the repo dir (cwd matters for file-fixture tests).
- **Mac `zig build test` is INSUFFICIENT for flip/ABI-class changes** — ubuntu-gate
  mandatory; arm64 masks x86_64 bugs. Rosetta `-Dtarget=x86_64-macos` REPRODUCES
  x86_64-linux JIT bugs. JIT-codegen fix → verify arm64 AND x86_64-macos.
- **Step-0.7 NOTE**: `failed command: …--listen=-` / host-example exe lines are
  COSMETIC (exit 0); trust `[run_remote_*] OK/FAIL` + `N passed, 0 failed`.
- CI `ci_gate.sh` runs `zig fmt` + `test-all` + (core) `run-rust-host` on the Linux
  leg (D-254) + (extended, push-to-main) lint/DCE/AOT/`zone_check`/`spill_aware_check`
  (promoted E-段2 + D-505). `file_size_check` is advisory-only (ADR-0099);
  `spill_aware_check` is also wired into `gate_commit.sh` (BASELINE=0, D-505). NOTE:
  extended runs only on push-to-main, so `zone_check`/`spill_aware` enforce
  post-merge, not as a PR blocker (a future refinement could run it once per PR).

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477 slivers** (partial, build-on-demand, no DIRECT consumer): v128 args/results
  invoke (Win64-by-ref gotcha); Win64 ≥4-param stack-spill; Win64 ≥2-arg/3-result
  MEMORY-class thunk. Recipe: `private/notes/d477-remaining-slices-design.md` + debt
  D-477. Trigger = a real consumer. SIMD correctness already covered (simd_assert
  25075/0 + fuzz-loader 1665 JIT-compiled clean). **D-478** = JIT FP host-callback
  bridge + funcref `Table.set` panic + proc_exit exit-code.
- **D-475 residual**: spec-harness cross-module register-table wiring only
  (applyImportedTablesFromRegistered + TableAlias pointer-sharing); the table64
  feature itself is COMPLETE on both engines.
- **D-502** CM utf16/latin1 canonical-ABI string encodings; **D-444** split
  `component_wasi_p2.zig` (2228 > 2000) — both Batch B (Component域).
- **validator.zig at 3392/3510** — next validator edit extracts per the marker plan first.
- D-305 long-tail (niche CM shapes; `component_graph.zig` 1895/2000 split first);
  D-464 async adversarial; D-462 feature-separation (user-gated). blocked-by rows = parked.

## State (release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM** default-ON;
  **0.3 core** done. Sandbox triad (fuel / interrupt / memory+table cap) cross-engine.
- **Surfaces**: C-API · Zig-API (full WASI parity) · lean CLI · memory-safety sound ·
  dogfooded into cljw (pins zwasm by git tag-hash). Runners ReleaseSafe.
- **EH**: cross-instance JIT EH both arches. Interp+JIT EH corpus green. Realworld 56
  fixtures interp 56/0; JIT diff-gated.
- **Debt**: 69 entries — **0 `now`-class** (D-505 DONE: 3 arm64-SIMD bitmask sites
  spill-aware, bitselect/fma SPILL-EXEMPT, spill_aware promoted to CI+gate_commit;
  follow-on D-506 = FP spill stage-2, note-class). 完成形 plateau (all dims
  confirmed, surface audits clean, interp+JIT fuzz 0-crash, v1-JIT parity D-265 closed).
- **Proposals**: reviewed 2026-07-03; no phase advances; 3.0 corpora unaffected.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0201** (funcref-table grow) ·
  **0172** (components=interp) · **0099** (file-size caps) · **0126** (iso-recursive equality).
  lessons INDEX: `.dev/lessons/INDEX.md`.
