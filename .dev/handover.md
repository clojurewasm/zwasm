# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.5.0 READY TO TAG (sweep COMPLETE 2026-08-12)**: the user-directed
pre-tag cleanliness sweep (S1-S6) is DONE — S1-S5 merged as #175, S6
(docs final-form) is the PR in flight / just merged. main carries
`build.zig.zon = 2.5.0` + the CHANGELOG section; remote tags end at
v2.4.1. **The only remaining step is the USER pushing the tag**
(`git tag v2.5.0 <sha> && git push origin v2.5.0` → release.yml
publishes; ADR-0156 — never autonomous). Prior line v2.4.1; v1 frozen
at `v1.11.1`. Dev model: `develop/<slug>` from `main` → PR → CI
`ci-required` green → merge.

**The repo moved to its own org 2026-08-12**: `clojurewasm/zwasm` →
**`zwasm/zwasm`** (`.dev/org_transfer_plan.md` phases 1-3 done; stars /
issues / releases / ruleset intact). Still open there: **phase 4** — the
Homebrew tap split (`zwasm/homebrew-tap` does not exist yet, so README's
install command deliberately still reads `clojurewasm/tap/zwasm`) and
**phase 5** (cljw pin + wind-down). Both are user actions.

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
- Doc-truth gaps #153/#154 + #163 CLOSED (prose gates live in the always-on
  CI **`doc-truth` job**). Binary-size CLOSED (ADR-0204). AOT full-fidelity
  CLOSED (ADR-0203; residual D-515(2)+D-514).

## Cleanliness sweep S1-S6 — COMPLETE (2026-08-12)

All six axes closed (plan was #168; S1-S5 consolidated+merged as #175):
- **S1** D-444 three-way split (ADR-0207) + full over-cap triage —
  `file_size_check` 0 WARN repo-wide (was 30); canon/types P1 seams
  scheduled post-tag (D-580/D-581).
- **S2** -Dgc + run-repro retired (D-525; ADR-0115/0015 revision notes);
  Windows sanitize rejects loudly; build-option table in development.md.
- **S3** --engine auto spellable; usage errors exit 2 uniformly; env
  surface audited (no hidden flags).
- **S4** audit fixes: ROADMAP links, blocked-by re-walk (6 dissolved
  barriers flipped w/ evidence), doc-states.
- **S5** four guards live: growth ratchet, compiler-truth test-discovery
  (28 dead tests revived), doc-fossil guard (doc-truth job), blocked-by
  age ladder. 
- **S6** README+docs final-form: 6 history docs archived w/ Doc-state,
  public docs carry ZERO personal-infra/private/ mentions, links verified.

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

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON; **0.3 FULL on all 3 OSes** (official 45/45, 0 skip). Sandbox
  triad cross-engine.
- **Surfaces**: C-API · Zig-API · lean CLI · memory-safety sound · dogfooded
  into cljw. Realworld 56 interp 56/0; JIT diff-gated. Debt: 0 `now`-class.

## Key refs

- `flake.nix` `.#gen-wasip3`; `docs/zig_api_design.md`; lessons INDEX. ADRs:
  **0156** (NO autonomous release) · **0153** (rework) · **0099** (file-size)
  · **0172** (components=interp) · **0205** (wasi03 campaign).
