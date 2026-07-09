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

- Post-v2.0.0 scaffolding campaign COMPLETE (#118–#122: ledger reconcile,
  E-段1+2 ratifications, Component域, rust-host gate D-254). **D-475
  table64-JIT** MERGED #127 → **v2.1.0 released** (@d5d685ad4).

## Active rework campaign — AOT-full-fidelity (opened 2026-07-09, USER-RATIFIED)

- **Goal (user directive)**: 本当の cwasm/AOT — deploy artifact stays `.wasm`;
  `.cwasm` = explicit `zwasm compile` output AND the transparent-cache value.
  A `.cwasm` must load back into the **FULL runtime** (cache-hit == cache-miss)
  covering ALL module classes; then **D-508** transparent `run --cache` on top.
- **Phase I Investigation DONE** (findings doc:
  `.dev/meta_audits/2026-07-09-aot-full-fidelity-investigation.md`; details in
  `private/notes/aot-campaign-*.md`): **D-516 now-class bug** (13 baked helper
  absolute addresses — GC/EH/call_indirect-lazy — PIE ASLR → `.cwasm` fatal
  signal in a fresh process; `compile` emits it silently) · **D-517**
  (memory.grow unsupported on cwasm path: ALL 7 Go + rust_compression die) ·
  **D-518** (start func not serialized → silently skipped, wrong results) ·
  ROI ~110ms compile tax on 3MB Go · architecture = deserialize-into-
  CompiledWasm + reuse setupRuntimeLinked (bakes no absolutes); helper
  de-baking via JitRuntime-field indirection (wazero pattern); trap table as
  offset-relative side section (wasmtime, = D-515); two-tier gate; versioned
  cache dir.
- **Phase II correctness net = test/aot/aot_process_diff.zig** (`zig build
  test-aot-diff`, in test-all) — CROSS-PROCESS `.wasm`-vs-`.cwasm` subprocess
  diff (in-process lanes can't see ASLR staleness) over realworld + crafted
  corpus (test/aot/corpus: GC/EH/call_indirect/grow/start). Baseline 46/62
  match; known gaps pinned in the expectation table (.wrong_result =
  deterministic D-517/D-518, RATCHET-FLIP forces table update in the fixing
  PR; .unsound = D-516 ASLR class, report-only).
- **NEXT: Phase III design ADR** (format evolution + full-runtime load +
  D-508 cache) → IV staged impl (stage-1 = helper de-baking = D-516 fix) →
  V retrospective. Branch/PR per stage; `ci-required` gates each.

## Active front — G-senior-gap (2026-07-06, /continue entry point)

Report = `.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`.
- **G1 = D-507 COMPLETE** (#131/#132/#133, ADR-0202 guard-page elision).
  Retrospective: measured scalar-elision perf ≈ NOISE — "biggest tier-free
  lever" REFUTED; the 1.75–3.9x gap vs wasmtime = optimising-tier codegen
  (**D-513**, user-gated). Elision kept (correct, code-size, base for D-509
  threads). AOT elision DISABLED pending D-515. Follow-up **D-514** (SIMD
  elision symmetry).
- **G3 = D-510 COMPLETE** (#135) — committed `zig build fuzz-diff` gate:
  memory-snapshot compare + dual JIT lanes (`.auto`/`.explicit`) + regression
  corpus. 2008-module campaign 0 mismatch. D-515(2) partially covered.
- **G2 = D-508 folded into the AOT-full-fidelity campaign** (above; scope
  corrected — see the D-508 row).
- Then: D-314(a) epoch-counter · note-class D-509 (threads campaign, own
  kickoff + ADR) · D-511/D-512 (demand-driven) · **D-513 (user-gated)**.
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

- **D-477 slivers** (partial, build-on-demand; trigger = a real consumer):
  v128 invoke / Win64 stack-spill / MEMORY-class thunk — recipe in the row +
  `private/notes/d477-remaining-slices-design.md`. **D-478** = JIT FP
  host-callback bridge + funcref `Table.set` panic + proc_exit exit-code.
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
