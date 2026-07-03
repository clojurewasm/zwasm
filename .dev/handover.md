# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.0.0 shipped to `main`** (tag `v2.0.0` @3da4c8681; release.yml auto-built
Release + Latest→v2). v1 frozen at `v1.11.1`. The from-scratch build campaign is
COMPLETE; the autonomous `/continue` loop is RETIRED. Dev model: cut a
`develop/<slug>` branch from `main` → PR → CI `ci-required` 3-OS gate must be
green to merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over. No active campaign/bundle; no cron self-re-arm.

## Active maintenance work (batched to keep CI frugal)

Post-v2.0.0 sweep (see `.dev/meta_audits/2026-07-03-maintenance-scaffolding-audit.md`):
- **Batch A — ledger/proposal reconcile** (doc-only) — MERGED #118. Debt reconciled
  vs code truth (closed D-294/296/297/322/500; reclassified D-254→now / D-249→note).
- **Batch E — scaffolding necessity audit** (doc-only) — MERGED #119. handover reshaped
  to a state doc; retired-loop skill triggers de-looped. **Pending USER decisions**
  (report §B/§C): file-size cap posture (ADR-0099), Windows-BATCHED / `gate_merge`
  cadence (ADR-0076/0174), and the relax-vs-promote-to-`ci_gate` fork.
- **Batch B — Component域** (code) — MERGED #120. D-502 utf16/latin1+utf16 canon
  string codec (lower+lift) COMPLETE (residual = `invokeStringExport` utf8-gate, see
  the D-502 note); D-504 discharged (wasi_p2 @panic→NoHostIo + fd.zig doc-rot).
- **Batch C — table64-JIT** (D-475) = queued code PR (Win64-risk, do with FRESH
  context). **D held.** **D-444** (component_wasi_p2 split) gated on the cap-posture decision.

## Operational invariants (keep using)

- **Win64 fast-repro** (~2min): cross-build `zig build test -Dtarget=x86_64-windows-gnu`
  on Mac (run-step "fails" but test.exe builds) → `scp` to windowsmini → ssh-run from
  the repo dir (cwd matters for file-fixture tests).
- **Mac `zig build test` is INSUFFICIENT for flip/ABI-class changes** — ubuntu-gate
  mandatory; arm64 masks x86_64 bugs. Rosetta `-Dtarget=x86_64-macos` REPRODUCES
  x86_64-linux JIT bugs. JIT-codegen fix → verify arm64 AND x86_64-macos.
- **Step-0.7 NOTE**: `failed command: …--listen=-` / host-example exe lines are
  COSMETIC (exit 0); trust `[run_remote_*] OK/FAIL` + `N passed, 0 failed`.
- CI `ci_gate.sh` runs `zig fmt` + `test-all` (+ JIT/DCE/AOT). It does NOT run
  `file_size_check`/`zone_check`/`spill_aware_check` — those are local `gate_commit.sh`
  only (see the scaffolding-audit report's load-bearing finding).

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477 slivers** (partial, build-on-demand, no DIRECT consumer): v128 args/results
  invoke (Win64-by-ref gotcha); Win64 ≥4-param stack-spill; Win64 ≥2-arg/3-result
  MEMORY-class thunk. Recipe: `private/notes/d477-remaining-slices-design.md` + debt
  D-477. Trigger = a real consumer. SIMD correctness already covered (simd_assert
  25075/0 + fuzz-loader 1665 JIT-compiled clean). **D-478** = JIT FP host-callback
  bridge + funcref `Table.set` panic + proc_exit exit-code.
- **D-475 table64-JIT** (Batch C): interp is fully conformant; JIT is guarded
  (`JitTable64Unsupported`). u32→u64 4-cycle bundle, Win64-risk — do with FRESH context.
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
- **Debt**: 61 entries — ZERO `now`-class (after Batch A/B). 完成形 plateau (all dims
  confirmed, surface audits clean, interp+JIT fuzz 0-crash, v1-JIT parity D-265 closed).
- **Proposals**: reviewed 2026-07-03; no phase advances; 3.0 corpora unaffected.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0201** (funcref-table grow) ·
  **0172** (components=interp) · **0099** (file-size caps) · **0126** (iso-recursive equality).
  lessons INDEX: `.dev/lessons/INDEX.md`.
