# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.5.0 TAG ON HOLD (user 2026-08-11)**: main (`f4157226d`, #167) already
carries `build.zig.zon = 2.5.0` + the cut CHANGELOG section — prepared but
NOT tagged (remote tags end at v2.4.1; verified). The user paused the tag to
run the cleanliness sweep (front below) first; the sweep is internal-only,
so it ships under the same v2.5.0 when the user tags
(`git tag v2.5.0 <sha> && git push origin v2.5.0` → release.yml publishes).
Prior line v2.4.1; v1 frozen at `v1.11.1`. Dev model: `develop/<slug>` from
`main` → PR → CI `ci-required` green → merge. **Release stays user-only
(ADR-0156)** — never autonomously tag / publish / cut over.

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

## Closed fronts (2026-08-11)

- **wasi03-full + windows port** (#165, ADR-0205): WASI 0.3 official corpus
  45/45 on all 3 OSes, 0 skip. **reproducible-dev-env** (#166, ADR-0206):
  `docs/development.md` SSOT + `dev_hosts.env` config + dead-script sweep.
  post-merge main CI green (incl. extended) for #165; #166's run was
  superseded-cancelled by #167's (same content verified on the #166 PR).

## Active front — 完成形 cleanliness sweep (user-directed 2026-08-11, PRE-TAG)

The NEXT session's mandate (user: 腰を据えて — design / build flags / runtime
options / directory+file organization all genuinely clean, PLUS mechanize
what failed to prevent the drift). Concrete axes, each → its own PR(s):

- **S1 file/dir organization**: 30 files over ADR-0099 caps (advisory since
  2026-07-03 — which is exactly why `component_wasi_p2.zig` grew 2228→5470
  SILENTLY, now over even its exempt cap; `jit_abi.zig` 2027 > hard cap).
  D-444 Phase-I is DONE (findings in the row, 2026-08-11): the one-way split
  premise is WRONG — 3 reverse deps + a generation-neutral host-stream
  engine ⇒ THREE-way split (shared substrate / P2 / P3) with vtable
  inversion. Run as ADR-0153 rework (II characterization net = 76+61
  sibling tests BEFORE moving code). Then triage the remaining over-cap
  list per ADR-0099 P/N conditions (split on positive, EXEMPT with real
  rationale otherwise).
- **S2 build-flag surface**: D-525 `-Dgc` is INERT (option exists, reader
  is dead) — fix or remove; audit the whole `-D` surface for tier
  coherence (`-Dwasm`/`-Dwasi` orderings, `-Dengine`, `-Dcompiler-rt`,
  `-Dtask`…) against docs/development.md + README claims.
- **S3 runtime/CLI option surface**: `zwasm --help` あるべき論 audit —
  naming/defaults/coverage vs the engine reality (auto/interp/jit), env
  vars (ZWASM_*) inventoried + documented or removed.
- **S4 doc/claim fossils**: the class found twice today (CLAUDE.md stuck at
  v2.0.0-rc.1; ubuntunote_setup referencing deleted scripts) — run
  `audit_scaffolding` §A–G full pass now that two campaigns closed
  back-to-back.
- **S5 mechanization (prevention)**: (a) file-size GROWTH ratchet — advisory
  cap can stay, but a file ALREADY over cap growing further in a PR should
  gate (delta-ratchet, not absolute); (b) version/claim fossil guard —
  extend the doc-truth job pattern; (c) whatever S2/S3 finds systemic.
- **S6 README+docs 完成形化 (user 2026-08-11, runs AFTER S1–S5)**: README +
  every doc it references — delete / archive / update to current state;
  final-form only (spec・status・guides), no development history (assume
  ~zero v1 users; cut docs/ sprawl). HARD: public docs get ZERO mentions
  of the personal 3-host SSH setup or `private/` (PC-local).
- Exit: axes S1–S6 each closed-or-ADR'd, THEN user tags v2.5.0.

## Active rework campaign

- **Campaign-ID**: s1-d444-three-way-split (D-444; branch `develop/s1-d444-three-way-split`)
- **Phase**: II — correctness assurance (of I→V; Phase-I findings live in the D-444 row)
- **Findings-doc**: D-444 debt row (structural map, 3 reverse deps, three-way shape)
- **Exit target**: component_wasi_p2.zig → shared substrate + P2 + P3 files, all under
  ADR-0099 caps or honestly EXEMPT; full test net green at every commit
- **Correctness net**: 76 (p3) + 61 (component_tests) sibling tests green baseline +
  characterization of the 3 reverse-dep paths BEFORE any code moves
- **Next**: coverage map of reverse-dep paths (survey running) → fill gaps as test-only chunks

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
  **D-526** doc-staleness sweep; D-464 long-tail.
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
