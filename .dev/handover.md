# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.4.1 is the release line** (tag cut 2026-08-04, USER-GRANTED per ADR-0156;
consumer-driven patch #157/#158/#159 from ClojureWasm). v2.4.0 = external-
consumer release (`-Dcompiler-rt` #154 + GC-cohort DCE #150); v2.3.0 =
WASI-0.3.0 sweep + Homebrew tap; v2.2.x = binary-size / AOT lines. v1 frozen
at `v1.11.1`. Dev model: cut a `develop/<slug>` branch from `main` → PR → CI
`ci-required` 3-OS gate green to merge. **Release stays user-only (ADR-0156)**
— never autonomously tag / publish / cut over.

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

## Active front — reproducible-dev-env (2026-08-11, user-directed)

Branch `develop/reproducible-dev-env` (from `d5824cb8b`). Goal: **anyone can
develop this project** — remove/generalize every implicit maintainer-
environment assumption (SSH host aliases ubuntunote/windowsmini, `private/`
scratch conventions, home-path references, setup docs scattered across
`.dev/`) into an SSOT contributor story with reproducible setup. CI (3-OS
`ci-required`) is already the authoritative gate — the local 3-host fan-out
must be clearly OPTIONAL and parameterized. Steps:
1. [ ] Inventory sweep (Explore subagent) of implicit assumptions — SSH hosts,
   abs paths, private/, tooling, setup-doc state, CI-vs-local coupling.
2. [ ] SSOT doc (docs/development.md or CONTRIBUTING expansion): fresh-clone
   → build → test → PR path with ZERO maintainer-specific hosts; name what's
   optional (remote gates, nix gen shells, private/).
3. [ ] Parameterize/guard remaining hardcoded host/path assumptions in
   scripts (env-var overrides exist partially: ZWASM_UBUNTU_HOST etc.).
4. [ ] post-merge main CI verify (run 31487010199; if red → root-cause fix
   FIRST, this front pauses).

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
