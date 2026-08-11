# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.5.0 release prep in flight (USER-GRANTED 2026-08-11 per ADR-0156)**:
this branch bumps `build.zig.zon` → 2.5.0 + cuts the CHANGELOG section
(headline: WASI 0.3 full coverage on all 3 OSes; also #162 C-API symbols,
#164 doc sweep, #166 dev-env SSOT). After merge + CI green the USER pushes
the `v2.5.0` tag → `release.yml` auto-builds + publishes. Prior line
v2.4.1 (2026-08-04); v1 frozen at `v1.11.1`. Dev model: cut a
`develop/<slug>` branch from `main` → PR → CI `ci-required` gate green to
merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over.

## Closed campaigns (details in the cited ADR/CHANGELOG)

- **wasi03-full + windows port — SHIPPED to main 2026-08-11** (PR #165, merge
  `d5824cb8b`; ADR-0205 phases A–F COMPLETE). Full WASI 0.3.0 coverage, all
  six proposals, official corpus **45/45 green on all 3 OSes, 0 skip**
  (D-568 + D-569 discharged). Platform substance: Linux SO_REUSEADDR-only
  listen (stdlib couples SO_REUSEPORT; `fastreuseport` bind-bucket cache);
  windows own NT/AFD socket control plane + NT hardlinks + pre-OS empty-path
  noent. Mechanism notes = code comments (`p2_sockets.zig` AFD section,
  `path.zig` winPathLink) + ADR-0205 F.
- Doc-truth gaps #153/#154 + #163 CLOSED (prose gates live in the always-on
  CI **`doc-truth` job**). Binary-size CLOSED (ADR-0204). AOT full-fidelity
  CLOSED (ADR-0203; residual D-515(2)+D-514).

## Closed front — reproducible-dev-env (SHIPPED 2026-08-11, PR #166 → dc46526c5)

ADR-0206: anyone can develop this project. `docs/development.md` SSOT
(README/CONTRIBUTING link it; honest CI claim — windows leg advisory);
`scripts/dev_hosts.env.example` per-machine host config for the OPTIONAL
fan-out; yq guards; 5 dead campaign scripts deleted. Verified by fresh-clone
Zig-only build/test + two clean-context agent audits (5 findings all fixed).
post-merge main CI green for both #165 (incl. extended) and #166.

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
  **D-444** split `component_wasi_p2.zig` (grew again in wasi03);
  **D-526** doc-staleness sweep; D-305/D-464/D-462 long-tail.
- G-senior-gap G1/G2/G3 COMPLETE
  (`.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`).

## State (release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON; **0.3 FULL on all 3 OSes** (official 45/45, 0 skip). Sandbox
  triad cross-engine.
- **Surfaces**: C-API · Zig-API · lean CLI · memory-safety sound · dogfooded
  into cljw. Realworld 56 interp 56/0; JIT diff-gated. Debt: 0 `now`-class.

## Key refs

- `flake.nix` `.#gen-wasip3`; `docs/zig_api_design.md`; lessons INDEX. ADRs:
  **0156** (NO autonomous release) · **0153** (rework) · **0099** (file-size)
  · **0172** (components=interp) · **0205** (wasi03 campaign).
