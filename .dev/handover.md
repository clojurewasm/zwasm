# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.3.0 is the release line** (tag cut 2026-07-17, USER-GRANTED in-session
per ADR-0156 — WASI-0.3.0-official sweep + system-clock + Homebrew tap
`brew install clojurewasm/tap/zwasm`; v2.2.1 = 2026-07-16 binary-size line,
v2.2.0 = 2026-07-09 AOT line). v1 frozen at `v1.11.1`. Dev model: cut
a `develop/<slug>` branch from `main` → PR → CI `ci-required` 3-OS gate must be
green to merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over. No active campaign; no cron self-re-arm.

## Binary-size campaign — CLOSED 2026-07-16 (ADR-0204 Implemented, v2.2.1)

Trigger = dogfooding mailbox `from_cljw_05` (cljw measures zwasm at 44% of
its shipped code). Kickoff #144 (measured attribution re-prioritized the
cljw asks) · stage 1 #145 (D-522: shared noinline fpBridge1/2 bodies —
jit_host_bridge 1,311→232 KB, **CLI −21%** ReleaseSafe, −8% ReleaseFast;
DA-critique 20/20) · close #146 (refutation record + v2.2.1). Key outcomes:
- **D-522 stage 1 SHIPPED**; stage 2 (slot-axis, ~200 KB) re-scored →
  demand-driven note in debt.yaml.
- **D-521 DISCHARGED — size premise refuted by measurement**: fn-ptr-table
  stage A left `emit.compile` at 707 KB, +28.8 KB binary → reverted. The
  giant symbol is once-called-handler AGGREGATION, not duplication. Lesson
  `2026-07-16-outlining-once-called-handlers-size-neutral.md` (predictive
  question = "how many call sites share this code?", not symbol size).
- ReleaseFast `base` had DOUBLED unnoticed since 2026-06-12 (1.97→3.88 MB;
  series cadence = phase-boundary only); now 3.56 MB. cljw replies
  `to_cljw_05/06.md` in the mailbox (x86_64 emitter already exists +
  4.0 MB budget-line revisit suggestion).

## AOT-full-fidelity campaign — CLOSED 2026-07-09 (ADR-0203 Implemented)

PRs #136-#142: format v0.5 full-fidelity, run-path swap (mini-runtime
DELETED), elision serialization, `--cache` (D-508). `zig build
test-aot-diff` 63/63 incl. cache lanes. Residual = D-515(2) + D-514
(debt.yaml). Details: ADR-0203 + CHANGELOG 2.2.0.

## WASI-0.3.0-official sweep — 2026-07-17 (branch develop/wasm30-wasi03-inventory-sweep)

**WASI 0.3.0 released 2026-06-11** (spec at `~/Documents/OSS/WASI/`, clones
pulled). Docs truth-sweep (README 0.3 row, --help/canon.zig/3.0-runner lies,
`-Dgc` is INERT → D-525) + `system-clock`/`get-resolution` host support
(instant{s64,u32}, DA check #12). Fixtures import 0.2.6 → D-523; async
wait-until/wait-for → D-524. Full diff = proposal_watch 2026-07-17 entry.

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
