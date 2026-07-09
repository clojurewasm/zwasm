# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.2.0 is Latest** (tag `v2.2.0` @cf5d20d72, 2026-07-09 — AOT-full-fidelity
campaign: transparent `--cache` 2.2x cold start · full-runtime `.cwasm` v0.5 ·
PIC codegen D-516 fix; release.yml auto-built Release + 5 assets; release was
USER-DIRECTED 2026-07-09 per ADR-0156). v1 frozen at `v1.11.1`. Dev model: cut
a `develop/<slug>` branch from `main` → PR → CI `ci-required` 3-OS gate must be
green to merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over. No active campaign/bundle; no cron self-re-arm.

## AOT-full-fidelity campaign — CLOSED 2026-07-09 (ADR-0203 Implemented)

Kickoff #136 (phases I–III) · stage 1 #137 (36 helper bakes → `[rt+off]`
slots, D-516) · stage 2 #138 (format v0.5 + `load_compiled.zig`
deserializer, D-519) · stage 3 #139 (run-path swap, mini-runtime DELETED,
§4.5.4 start-func JIT bug fixed, D-517+D-518, D-520 CI hole) · stage 4
#140 (elision serialization D-515(1)) · stage 5 #141 (`--cache` D-508;
DA-critique failure-path fixes: HIT header-gate + self-heal, refusal =
BYPASS, interp bypass) · stage V #142 (retro: bench parity record, docs,
`.cwasm --engine interp` loud refusal, lesson
failure-path-tests-certified-the-defect). Net: `zig build test-aot-diff`
cross-process differential 63/63 incl. cache lanes. **Residual =
D-515(2)** (spec-assert corpus under elision; harness memory
provisioning) + D-514 (SIMD elision symmetry) — both in debt.yaml.

## Active front — G-senior-gap (2026-07-06, /continue entry point)

Report = `.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`.
- **G1 = D-507 COMPLETE** (#131/#132/#133, ADR-0202 guard-page elision).
  Retrospective: measured scalar-elision perf ≈ NOISE — "biggest tier-free
  lever" REFUTED; the 1.75–3.9x gap vs wasmtime = optimising-tier codegen
  (**D-513**, user-gated). Elision kept (correct, code-size, base for D-509
  threads). AOT elision ENABLED at ADR-0203 stage 4 (D-515(1)). Follow-up
  **D-514** (SIMD elision symmetry).
- **G3 = D-510 COMPLETE** (#135) — committed `zig build fuzz-diff` gate:
  memory-snapshot compare + dual JIT lanes (`.auto`/`.explicit`) + regression
  corpus. 2008-module campaign 0 mismatch. D-515(2) partially covered.
- **G2 = D-508 COMPLETE** via the AOT-full-fidelity campaign (above).
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
- **Debt**: 68 entries — **0 `now`-class** (D-505 DONE: 3 arm64-SIMD bitmask sites
  spill-aware, bitselect/fma SPILL-EXEMPT, spill_aware promoted to CI+gate_commit;
  follow-on D-506 = FP spill stage-2, note-class). 完成形 plateau (all dims
  confirmed, surface audits clean, interp+JIT fuzz 0-crash, v1-JIT parity D-265 closed).
- **Proposals**: reviewed 2026-07-03; no phase advances; 3.0 corpora unaffected.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0201** (funcref-table grow) ·
  **0172** (components=interp) · **0099** (file-size caps) · **0126** (iso-recursive equality).
  lessons INDEX: `.dev/lessons/INDEX.md`.
