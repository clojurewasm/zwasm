# ADR-0206: Reproducible dev environment — contributor-generalized SSOT

- **Status**: Accepted
- **Date**: 2026-08-11
- **Front**: reproducible-dev-env (user-directed 2026-08-11)
- **Findings base**: full-repo implicit-assumption inventory (Explore sweep,
  this session): SSH-host aliases, home paths, `private/` conventions,
  setup-doc fragmentation, tool guards, CI-vs-local gate coupling.

## Context

zwasm's development workflow accreted around one maintainer's machines: SSH
gate hosts (`ubuntunote` / `windowsmini`), an author-local reference-clone
layout (`~/Documents/OSS`), a gitignored `private/` scratch tree, Nix-applied
git hooks, and setup docs scattered across `.dev/*.md`. The authoritative
merge gate has ALREADY moved to GitHub CI (`ci-required`, 3-OS, per ADR-0076
D9) — but the docs and scripts still frame the local 3-host fan-out as the
norm, and nothing tells a fresh contributor "you need none of that". The goal
(user-directed): anyone can clone, build, test, and land a PR with zero
knowledge of the maintainer's environment.

## Decisions

### D1 — `docs/development.md` is the contributor SSOT

One entry-point doc covering: fresh clone → build → test (Zig-only and Nix
paths), the test-tier map, git-hooks activation for non-Nix users, the tool
matrix (required vs optional), and an explicit statement that **GitHub CI
(`ci-required`) is the authoritative 3-OS gate — no SSH hosts, no `private/`,
no Nix are required to contribute**. Every other doc (README, CONTRIBUTING,
`.dev/README.md`) POINTS there instead of duplicating content.

- Rejected: expanding CONTRIBUTING.md in place — community-health files in
  `.github/` are conventionally short; the dev-environment story belongs
  with the shipped docs (`docs/`), where it is versioned with the code it
  describes.

### D2 — Maintainer-specific environment is labeled, optional, and parameterized

- `.dev/README.md` splits its index into "load-bearing project record" vs
  "maintainer-host setup (optional — CI is the gate)".
- **`scripts/dev_hosts.env` (gitignored; committed template
  `dev_hosts.env.example`)** is the per-machine host config: anyone with
  their own architecture-matched hosts copies one file, edits three values
  (`ZWASM_UBUNTU_HOST` / `ZWASM_WINDOWS_HOST` / `ZWASM_REMOTE_DIR`), and the
  whole local fan-out works. Every remote-gate script sources it; the file
  uses `: "${VAR:=…}"` so an exported env var still wins, and the scripts'
  built-in defaults apply when neither is set. Stragglers that hardcoded a
  host (`win64_debug/attach_dump.sh`) adopt the same pattern.
- `private/` is documented as maintainer scratch that no build/test path
  requires; scripts touching it keep (or gain) absent-dir guards.

### D3 — Required-tool guards fail with instructions, not stack traces

Scripts whose hard dependency is not in the default toolchain check for it
and print the install pointer: `yq` (mikefarah v4) in the `check_*` gates
that parse `debt.yaml` — a fresh clone without `yq` currently dies with a
bash error inside the pre-commit hook. Zig itself stays unguarded (it is THE
toolchain; its absence is self-evident).

### D4 — Campaign-era docs stay historical, not normative

`.claude/skills/continue/{GATE,LOOP,RESUME,REWORK,STOP_BUCKETS}.md` and the
debug recipes keep their maintainer-host references — they are explicitly
"retired campaign machinery, kept as historical reference" (skill header).
Normative framing lives only in CLAUDE.md + `docs/development.md` +
CONTRIBUTING; the pre-push hook header drops its mandatory-sounding 3-host
language in favor of "CI is authoritative".

### D5 — Dead campaign scripts are DELETED, not archived

git history is the archive; a `scripts/` directory a newcomer must triage is
the cost being paid down. Deleted (each self-declared dead or superseded):
`should_gate_windows.sh` (DEPRECATED stub, machinery removed 2026-07-03),
`orb_test_all_with_d134_retry.sh` (OrbStack gate retired, ADR-0067),
`p9_simd_status.sh` (phase-9 one-shot, hardcoded host),
`check_subrow_exit.sh` (self-declared DORMANT, never fires post-phase-9),
`migrate_debt_to_yaml.py` (one-shot migration, ADR-0129 records it).
Retained deliberately: `check_phase{9,10}_close_invariants.sh` (invoked by
the live `dispatch_consistency_audit` skill), `mac_gate.sh` /
`check_three_host_diff.sh` (small, self-contained maintainer conveniences),
campaign-era `.claude/skills/continue/` sub-docs (labeled historical, D4).

## Consequences

- README links Contributing + `docs/development.md` (it linked neither).
- A contributor without Nix gets told how to activate `.githooks` (Nix's
  shellHook did it silently; non-Nix users previously got no hooks and no
  notice).
- ROADMAP §A7/A8 gate framing is NOT edited here (campaign-era history);
  the maintenance-mode reality (CI authoritative) is already recorded in
  CLAUDE.md + ADR-0076 D9 and now in the SSOT doc.

## Revision history

- 2026-08-12 (D2 revision, user-directed) — **the two SSH host names lost
  their in-repo defaults.** `ZWASM_UBUNTU_HOST` / `ZWASM_WINDOWS_HOST` no
  longer fall back to the maintainer's aliases: unset now means "no such
  host", so `gate_merge.sh` WARNs and skips that leg and the per-host
  runners exit 2 pointing at `dev_hosts.env.example`. `ZWASM_REMOTE_DIR`
  keeps a default, now the neutral `zwasm` instead of the maintainer's
  `Documents/MyProducts/zwasm`. D2's parameterization stands as written;
  what changed is that the parameter is genuinely unset out of the box, so
  a clone carries no machine identity — the same reason D1 exists. The
  maintainer's own values live in the gitignored `dev_hosts.env`, which
  D2 already requires.
