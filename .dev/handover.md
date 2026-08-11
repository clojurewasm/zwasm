# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.4.1 is the release line** (tag cut 2026-08-04, USER-GRANTED in-session per
ADR-0156 — consumer-driven patch: a component with 2+ exports failed validation
(#157, plus the follow-on it exposed where an export satisfied its own sortidx
bound) + a capture buffer had no bound (#158/#159, ~64 GB reachable). Both were
found from ClojureWasm and neither was reachable by zwasm's own fixtures; cljw
is re-pinned to the tag. v2.4.0 = 2026-08-03 external-consumer release
(`-Dcompiler-rt` #154 + sub-3.0 GC-cohort DCE #150); v2.3.0 = 2026-07-17
WASI-0.3.0 sweep + Homebrew tap `brew install clojurewasm/tap/zwasm`; v2.2.1 =
binary-size line, v2.2.0 = AOT line). v1 frozen at `v1.11.1`. Dev model: cut a
`develop/<slug>` branch from `main` → PR → CI `ci-required` 3-OS gate must be
green to merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over. No active campaign; no cron self-re-arm.

## Consumer-reported doc-truth gaps — both CLOSED (reporter `jtakakura`)

- **compiler-rt, 2026-08-03 (#153/#154).** Static `.a` never bundles
  compiler-rt (docs + D-312 claimed opposite) → opt-in `-Dcompiler-rt=true`;
  `test_extlink.sh` asserts on CI extended. Lesson `2026-08-03-ungated-…`.
- **Default engine, 2026-08-10 (#163).** "interp is default" outlived the
  `auto` flip in 5 places (doc-only PRs skip the gate) → new always-on CI
  **`doc-truth` job — put any future prose gate there** +
  `check_engine_default_claims.sh`. Lesson `2026-08-10-doc-only-ci-skip-…`.

## Closed campaigns (residual debt only — details in the cited ADR/CHANGELOG)

- **Binary-size** — CLOSED 2026-07-16 (ADR-0204, v2.2.1). D-522 stage 2
  demand-driven; D-521 discharged (premise refuted by measurement, lesson
  `2026-07-16-outlining-…-neutral.md`).
- **AOT full-fidelity** — CLOSED 2026-07-09 (ADR-0203, v2.2.0). `test-aot-diff`
  63/63. Residual = D-515(2) + D-514.

## Active front — wasi03-full (2026-08-10, ADR-0205, user-directed)

Full WASI 0.3 coverage campaign (six 0.3.0 proposals; `@unstable` excluded).
Conformance = vendored official `prod/testsuite-base` wasip3 binaries
(`=0.3.0`-pinned, dual-world 0.2+0.3 imports), run by an in-process
manifest-driven harness in `component_wasi_p3.zig` (`test-wasi-p3`).
- **A substrate — DONE/green** (commit 8a793863f): generation-aware dispatch
  groundwork, timer subtask waitable + `driveScheduler` sleep seam,
  `wait-until`/`wait-for`, `exit-with-code`. Closes D-524.
- **B filesystem — DONE/green** (commit 6d95ac124): full `wasi:filesystem@0.3.0`
  (async-eager metadata family + via-stream data plane + read-directory);
  generation-aware `WasiGen` dispatch. Official fs corpus 14/14.
- **C sockets — TCP COMPLETE/green** (this branch): control plane + connected
  data plane; official corpus 8/12 (tcp bind/listen/send/receive/echo + 3
  control). Keys: parked socket reads EXECUTE at readiness (a payload-0
  "re-read poke" reads as end-of-stream), tcp.send future resolves at
  tx-drop/drain-error (NOT eager), stream-drop halves = SHUT_WR/SHUT_RD,
  harness external-actor seam plays echo's remote client. NEXT (D-568 row has
  full detail): udp trio (OS-level udp connect for implicit-bind local-ip +
  sendTo EINVAL) → tcp-connect explicit-bind (needs raw bound-connect;
  darwin = ADR-0070 amendment) → resolve-addresses real DNS.
- **D http — NOT STARTED** (D-568): `wasi:http@0.3.0` largest remaining surface.
- **E claims sweep** — pending C/D.
28 official tests vendored green. 0.3.1 released 2026-08-11 (WIT diff vs 0.3.0
= 3 doc lines; release train bi-monthly, tracked per ADR-0205 D6).

## G-senior-gap front (2026-07-06) — G1/G2/G3 all COMPLETE

Report = `.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`; tail
rows tracked in debt.yaml (D-314(a), D-509, D-444, D-506, D-502/D-475).

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
  (promoted E-段2 + D-505). `file_size_check` is advisory-only (ADR-0099). NOTE:
  extended runs only on push-to-main, so `zone_check`/`spill_aware` enforce
  post-merge, not as a PR blocker. Doc-only PRs skip `gate` entirely — the
  always-on `doc-truth` job is the only PR-blocking leg they get.

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477 slivers** (partial, build-on-demand; trigger = a real consumer): v128
  invoke / Win64 stack-spill / MEMORY-class thunk — recipe in the row. **D-478**
  = JIT FP host-callback bridge + funcref `Table.set` panic + proc_exit code.
- **D-475 residual**: spec-harness cross-module register-table wiring only
  (applyImportedTablesFromRegistered + TableAlias pointer-sharing); the table64
  feature itself is COMPLETE on both engines.
- **D-502** CM utf16/latin1 canonical-ABI string encodings; **D-444** split
  `component_wasi_p2.zig` (2228 > 2000) — both Batch B (Component域).
- **validator.zig at 3392/3510** — next validator edit extracts per the marker plan first.
- D-305 long-tail (niche CM shapes; `component_graph.zig` 1895/2000 split first);
  D-464 async adversarial; D-462 feature-separation (user-gated). blocked-by rows = parked.
- **D-526** — external-contributor reproducibility / doc-staleness sweep (full
  gap list in the row; companion ClojureWasm D-565; mechanisable parts → CI
  `doc-truth` job, see #163 above).

## State (release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM** default-ON;
  **0.3 core** done. Sandbox triad (fuel / interrupt / memory+table cap) cross-engine.
- **Surfaces**: C-API · Zig-API (full WASI parity) · lean CLI · memory-safety sound ·
  dogfooded into cljw (pins zwasm by git tag-hash). Runners ReleaseSafe.
- **EH**: cross-instance JIT EH both arches; interp+JIT corpus green. Realworld 56
  fixtures interp 56/0; JIT diff-gated.
- **Debt**: 69 entries — **0 `now`-class** (D-505 DONE; follow-on D-506 = FP spill
  stage-2, note-class). 完成形 plateau (all dims confirmed, surface audits clean,
  interp+JIT fuzz 0-crash, v1-JIT parity D-265 closed).
- **Proposals**: reviewed 2026-07-03; no phase advances; 3.0 corpora unaffected.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`;
  [`docs/zig_api_design.md`](../docs/zig_api_design.md); lessons INDEX
  `.dev/lessons/INDEX.md`. ADRs: **0156** (NO autonomous release) · **0153**
  (rework) · **0201** (funcref-table grow) · **0172** (components=interp) ·
  **0099** (file-size caps) · **0126** (iso-recursive equality).
