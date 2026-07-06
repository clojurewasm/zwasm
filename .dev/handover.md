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

## Active maintenance work (batched to keep CI frugal)

Post-v2.0.0 sweep (see `.dev/meta_audits/2026-07-03-maintenance-scaffolding-audit.md`):
- **Batch A — ledger/proposal reconcile** (doc-only) — MERGED #118. Debt reconciled
  vs code truth (closed D-294/296/297/322/500; reclassified D-254→now / D-249→note).
- **Batch E — scaffolding necessity audit** — E-段1 report + de-loop MERGED #119.
  E-段2 (§B/§C decisions RATIFIED by user, all recommendations) MERGED #121 —
  file-size cap → ADVISORY (ADR-0099); Windows-BATCHED/`gate_merge` cadence RETIRED,
  `gate_merge` demoted to optional pre-flight (ADR-0076 D9 / ADR-0174 superseded);
  `zone_check` PROMOTED into `ci_gate.sh`. `spill_aware_check` PROMOTED too (D-505
  DONE — 3 bitmask sites made spill-aware, bitselect/fma SPILL-EXEMPT; now wired
  into gate_commit + CI extended, BASELINE=0).
- **Batch B — Component域** (code) — MERGED #120. D-502 utf16/latin1+utf16 canon
  string codec (lower+lift) COMPLETE (residual = `invokeStringExport` utf8-gate, see
  the D-502 note); D-504 discharged (wasi_p2 @panic→NoHostIo + fd.zig doc-rot).
- **D-254 — rust-host CI gate** — MERGED #122. `run-rust-host` now runs on the ubuntu
  gate leg (Linux-guarded core). Scaffolding-maintenance campaign (A→E→B + D-254) COMPLETE.
- **Batch C / D-475 — table64-JIT** — MERGED #127; **v2.1.0 released** (tag
  @d5d685ad4, Latest). Adversarial-review fixes (spilled-i64-grow W-store,
  bounds wrap) landed pre-merge; 11 table64 dirs JIT-native; 3-host green.

## Active front — G-senior-gap (2026-07-06, /continue entry point)

Senior-runtime gap analysis (measured; report =
`.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`) opened front
**G-senior-gap** (debt D-507..D-513, `front: G-senior-gap`). Queue order:
- **G1 = D-507 (IN PROGRESS)** — guard-page/signal bounds-check elision.
  **ADR-0202 filed** (adversarially critiqued + revised — read it first: D2
  merges classification INTO the ADR-0166 handlers, SIGSEGV+SIGBUS, oob_stub_off
  must be plumbed through EmitOutput→linker, binding-time soundness invariant).
  Branch `develop/d507-guard-page-bounds-elision`: **phase 1 (D1) DONE** —
  `platform/guarded_mem.zig` + `runtime/instance/memory_backing.zig`; all 4
  creation surfaces + 5 grow paths + 3 free paths switched; test-all green on
  Mac; std.c.mprotect = ADR-0070 B133. NEXT: phase 2 = D3 Zone-0 trap registry
  + D2 fault→trap PC-redirect handler (test proves redirect BEFORE elision);
  then phase 3 = D4 emit flip + D5 knob/.cwasm. D-510 is the safety net.
- **G2 = D-508** — on-disk compilation cache (reuse .cwasm serialization).
- **G3 = D-510** — committed differential-fuzz harness (interp oracle vs JIT);
  MAY be pulled ahead of D-507 as its safety net — either order is sanctioned.
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
- **Debt**: 62 entries — **0 `now`-class** (D-505 DONE: 3 arm64-SIMD bitmask sites
  spill-aware, bitselect/fma SPILL-EXEMPT, spill_aware promoted to CI+gate_commit;
  follow-on D-506 = FP spill stage-2, note-class). 完成形 plateau (all dims
  confirmed, surface audits clean, interp+JIT fuzz 0-crash, v1-JIT parity D-265 closed).
- **Proposals**: reviewed 2026-07-03; no phase advances; 3.0 corpora unaffected.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0201** (funcref-table grow) ·
  **0172** (components=interp) · **0099** (file-size caps) · **0126** (iso-recursive equality).
  lessons INDEX: `.dev/lessons/INDEX.md`.
