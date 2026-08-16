# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.5.0 TAGGED and published**; prior line v2.4.1; v1 frozen at
`v1.11.1`. Dev model: `develop/<slug>` from `main` → PR → CI
`ci-required` green → merge. Release stays user-only (ADR-0156) — an
agent-autonomy guardrail, not a bar to release automation.

**The repo moved to its own org 2026-08-12**: `clojurewasm/zwasm` →
**`zwasm/zwasm`** (`.dev/org_transfer_plan.md` phases 1-3 done; stars /
issues / releases / ruleset intact). **Phase 4's repo side is done too** —
`zwasm/homebrew-tap` carries `Formula/zwasm.rb`, the old tap keeps only
`cljw.rb` plus `tap_migrations.json`, and README installs from
`zwasm/tap/zwasm` (#181). Left to the user: phase 4 item 10 (verify from a
clean `brew` state) and **phase 5** (cljw pin + wind-down).

## In flight (2026-08-16)

- **#186** (jit: trap on a null table funcptr instead of executing it) and
  **#183** (ADR-0208 — gate WASI preview1 on the official testsuite): both
  CI-green and mergeable, **awaiting maintainer review since 2026-08-14**.
  Do not refresh them against `main` until the review lands.
- **Landed 2026-08-16**: #190 (D-592 retracted — the build-cache mechanism it
  claimed does not hold; the real defect was `run_oob_trap` never re-running),
  #192 (the JIT realworld differential had no caller — now in `test-all` with
  denominator accounting), #191 / #193 (records).
- `develop/wasi-p1-official-impl` carries #183's implementation — 147 files
  (vendored corpus + runner + advisory gate), pushed, **no PR**; it lands with
  the ADR once the review answers.
- **Next dispatchable — the wasmtime differential is double fail-open.**
  `test/realworld/diff_runner.zig` has a `matched < 30` denominator gate that is
  bypassed on any host without a working wasmtime: two early returns precede it
  — the oracle missing (`SKIP-WASMTIME-MISSING`) and the oracle resolving but
  every spawn failing (`SKIP-WASMTIME-UNUSABLE`). `.github/workflows/ci.yml`
  installs wasmtime with `continue-on-error: true`, so absent OR broken, the
  lane goes GREEN without running. Fixing it touches `ci.yml`, so it is not a
  maintainer-free change.

## Closed campaigns (details in the cited ADR/CHANGELOG)

- **wasi03-full + windows port — SHIPPED to main 2026-08-11** (PR #165, merge
  `d5824cb8b`; ADR-0205 phases A–F COMPLETE). Full WASI 0.3.0 coverage, all
  six proposals, official corpus **45/45 green on all 3 OSes, 0 skip**
  (D-568 + D-569 discharged). Platform substance: Linux SO_REUSEADDR-only
  listen (stdlib couples SO_REUSEPORT; `fastreuseport` bind-bucket cache);
  windows own NT/AFD socket control plane + NT hardlinks + pre-OS empty-path
  noent. Mechanism notes = code comments (`p2_sockets.zig` AFD section,
  `path.zig` winPathLink) + ADR-0205 F.
- **reproducible-dev-env** (#166, ADR-0206): `docs/development.md` SSOT +
  `dev_hosts.env` config + dead-script sweep. Post-merge main CI green
  (incl. extended) for #165; #166's run superseded-cancelled by #167's.
- **Pre-v2.5.0 cleanliness sweep S1-S6 — COMPLETE 2026-08-12** (#175 + #176;
  ADR-0207): `file_size_check` 0 WARN repo-wide, -Dgc/run-repro retired
  (D-525), CLI + build-option surfaces audited, four mechanized guards live
  (growth ratchet · test-discovery · doc-fossil · blocked-by ladder),
  README/docs final-form with zero personal-infra mentions.
- Doc-truth gaps #153/#154 + #163 CLOSED (prose gates live in the always-on
  CI **`doc-truth` job**). Binary-size CLOSED (ADR-0204). AOT full-fidelity
  CLOSED (ADR-0203; residual D-515(2)+D-514).

## Operational invariants (keep using)

- **Win64 fast-repro** (~2min): cross-build on Mac (run-step "fails" but
  test.exe builds) → `scp` to windows host → ssh-run from the repo dir.
- **Mac `zig build test` is INSUFFICIENT** for flip/ABI/platform-branch
  changes — ubuntu+windows gates mandatory; arm64/POSIX masks the rest (the
  wasi03 campaign's "45/45" was a POSIX-only claim; Linux hid 3, windows 10).
- **Step-0.7 NOTE**: `failed command: …--listen=-` / host-example exe lines
  are COSMETIC (exit 0); trust `[run_remote_*] OK/FAIL` + `N passed, 0 failed`.
- CI `ci_gate.sh` = fmt + `test-all` + (core) `run-rust-host` + (extended)
  lint/DCE/AOT/`zone_check`/`spill_aware`. Doc-only PRs: `doc-truth` job only.

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477/D-478** JIT slivers (build-on-demand); **D-475 residual**
  spec-harness register-table wiring; **D-502** CM string encodings;
  **D-526** doc-staleness sweep; D-464 long-tail. (D-444 discharged
  2026-08-12, ADR-0207.)
- G-senior-gap G1/G2/G3 COMPLETE
  (`.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`).

## State (release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip **on the engine CI runs**. The JIT
  spec lane is opt-in (`ZWASM_SPEC_ENGINE=jit`) and is NOT in CI, so that row
  is not currently re-derivable for both engines.
- **WASI 0.1**: syscall SURFACE complete (46/46, ADR-0161). Behaviour against
  the official wasi-testsuite was measured 2026-08-14 at **58/72 interp,
  54/72 jit** (x86_64-linux; wasmtime 47.0.3 scores 72/72 through the same
  harness) — nothing gated that until now. ADR-0208 (#183) proposes the gate
  (D-582 infra, D-583 the 14 behaviour gaps). **0.2/CM** default-ON; **0.3
  FULL on all 3 OSes** (official 45/45, 0 skip). Sandbox triad cross-engine.
- **Surfaces**: C-API · Zig-API · lean CLI · memory-safety sound · dogfooded
  into cljw. Realworld 56/0 vs wasmtime under `--engine jit`, gating in
  `test-all` since 2026-08-16 (`test-realworld-diff-jit`) **on hosts where
  wasmtime resolves** — elsewhere the lane skips and only the self-differential
  gates (D-283); before that it was fatal in the runner but wired into nothing.
  **The paired lane is NOT interp**: default `Limits` = `.auto` prefers the JIT
  — measured, 7 of 56 fixtures provably do not take the interp, so `test-all`
  has no forced-interp result-check over the realworld corpus.

## Key refs

- `flake.nix` `.#gen-wasip3`; `docs/zig_api_design.md`; lessons INDEX. ADRs:
  **0156** (NO autonomous release) · **0153** (rework) · **0099** (file-size)
  · **0172** (components=interp) · **0205** (wasi03 campaign).
