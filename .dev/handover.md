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
- **A substrate — DONE/green** (8a793863f): timer waitables + scheduler seam +
  `wait-until`/`wait-for` + `exit-with-code`. Closes D-524.
- **B filesystem — DONE/green** (6d95ac124): full `wasi:filesystem@0.3.0`;
  official fs corpus 14/14; generation-aware `WasiGen` dispatch.
- **C sockets — COMPLETE/green**: official 12/12 on POSIX (control + TCP/UDP
  data planes + ip-name-lookup real DNS). Keys: parked reads EXECUTE at
  readiness, tcp.send future non-eager, stream-drop = SHUT_WR/SHUT_RD,
  udp connect = OS dgram connect, explicit-bind connect = raw posix
  (ADR-0070 amendment; windows carve-out = D-569 skip).
- **D http — COMPLETE/green**: full `wasi:http@0.3.0` (types resources +
  handler EXPORT + client.send). Model = src/wasi/p3_http.zig. Keys: `new`
  consumes headers/options owns (immutable after); harness drives the guest's
  exported handler.handle per manifest `request` op (service world = no
  cli/run); task.return generalizes to >1-flat results via defineFuncRaw;
  client.send parks as a subtask + real std.http.Client exchange (harness
  echo endpoint on a bg thread → HTTP_ENDPOINT); `resolveDroppedPeers` (poll
  seam) completes a parked copy whose peer dropped after it parked.
- **E claims sweep — DONE**: README/migration/ROADMAP/CHANGELOG flipped to
  full-coverage; `check_wasi03_coverage_claims.sh` doc-truth guard wired into
  CI. ADR-0205 = COMPLETE.
Official corpus **45/45 green** on POSIX (tcp-connect windows-skip = D-569).
**Campaign done — branch ready for a PR to `main`** (CI `ci-required` 3-OS
gate is the authoritative check for the branch; local ubuntu gate syncs
`origin/main` so it does NOT cover this branch). 0.3.1 (2026-08-11) WIT diff
vs 0.3.0 = 3 doc lines (release train per ADR-0205 D6).

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
- CI `ci_gate.sh` = `zig fmt` + `test-all` + (core) `run-rust-host` + (extended,
  push-to-main only) lint/DCE/AOT/`zone_check`/`spill_aware`. Doc-only PRs skip
  `gate`; the always-on `doc-truth` job is their only PR-blocking leg (now runs
  both `check_engine_default_claims` + `check_wasi03_coverage_claims`).

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477 slivers** (partial, build-on-demand; trigger = a real consumer): v128
  invoke / Win64 stack-spill / MEMORY-class thunk — recipe in the row. **D-478**
  = JIT FP host-callback bridge + funcref `Table.set` panic + proc_exit code.
- **D-475 residual**: spec-harness cross-module register-table wiring only
  (applyImportedTablesFromRegistered + TableAlias pointer-sharing); the table64
  feature itself is COMPLETE on both engines.
- **D-502** CM string encodings; **D-444** split `component_wasi_p2.zig`
  (now 4700+ > 2000; grew in this campaign — Batch B Component域); **D-526**
  external-contributor doc-staleness sweep; **validator.zig 3392/3510**;
  D-305 / D-464 / D-462 long-tail. blocked-by rows = parked.

## State (release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON; **0.3 FULL** (all six proposals, official 45/45). Sandbox triad
  cross-engine.
- **Surfaces**: C-API · Zig-API (full WASI parity) · lean CLI · memory-safety
  sound · dogfooded into cljw. EH cross-instance JIT both arches. Realworld 56
  interp 56/0; JIT diff-gated.
- **Debt**: 76 entries — 0 `now`-class. 完成形 plateau.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`;
  [`docs/zig_api_design.md`](../docs/zig_api_design.md); lessons INDEX
  `.dev/lessons/INDEX.md`. ADRs: **0156** (NO autonomous release) · **0153**
  (rework) · **0201** (funcref-table grow) · **0172** (components=interp) ·
  **0099** (file-size caps) · **0126** (iso-recursive equality).
