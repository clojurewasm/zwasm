# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> Pointers only — detailed plans live in [`.dev/ROADMAP.md`](../.dev/ROADMAP.md),
> runnable procedures in [`.claude/skills/`](skills/). (The autonomous
> `/continue` build-campaign loop is RETIRED post-merge — maintenance mode.)

## Identity

**Project name (in all docs and the published artifact): `zwasm`.**
Binary / package: `zwasm`.

zwasm v2 is a ground-up redesign of zwasm (v1 git history at commit 517cc5a).
**As of 2026-07-01 the from-scratch campaign is COMPLETE**: v2 shipped to
`main` (replace-merge `dbd43f89e`); v1 is frozen at tag `v1.11.1`.

- Working dir: `~/Documents/MyProducts/zwasm/` (unified — the separate
  `zwasm_from_scratch/` working dir is retired).
- **`main` is the trunk.** Dev model: cut a `develop/<slug>` branch from
  `main`, PR to `main`. `main` is **server-side ruleset-protected**: no direct
  push, PR required, and the `ci-required` status check (CI's 3-OS gate) must be
  green to merge; only the repo admin can bypass. Doc-only PRs auto-skip the
  heavy gate (still green via `ci-required`). The local 3-host gate
  (`scripts/gate_merge.sh`, A13) mirrors CI for pre-PR verification. `--force`
  always forbidden. Root is kept lean (ADR-mirroring the CW layout): this file
  is `.claude/CLAUDE.md`; community-health files (CONTRIBUTING / CODE_OF_CONDUCT /
  SECURITY) are in `.github/`; `THIRD_PARTY.md` is in `legal/`; `examples/` is
  under `docs/examples/`. Only README / LICENSE / CHANGELOG / build+flake files
  remain at root.
- **Release stays user-only (ADR-0156)**: tag / publish / cutover are
  manual. Current line = `v2.0.0-rc.1` (tag-only; Latest = v1.11.1).
  `v2.0.0` final = bump `build.zig.zon` + push `v2.0.0` tag → `release.yml`
  auto-builds + Release + Latest→v2. See `docs/migration_v1_to_v2.md`.
- v1 ABI compatibility is out of scope; the C/Zig/CLI surfaces broke v1 on
  purpose (ADR-0156).

Read-only reference clones: `~/Documents/OSS/` + `zwasm/` (v1) +
`ClojureWasmFromScratch/`. Full list at
[`.dev/reference_clones.md`](../.dev/reference_clones.md); mirrored in
`additionalDirectories` setting. Never edit or commit from these
paths. Pre-redesign investigation: `~/zwasm/private/v2-investigation/`.

## Language policy

Public project. **English by default** for code, comments, identifiers,
commit messages, README, ROADMAP, ADRs, `.dev/`, `.claude/`, all config.
**Japanese** for chat replies only. Enforced by
[`.claude/output_styles/japanese.md`](output_styles/japanese.md)
+ SessionStart hook.

**Bilingual exception**: meta-prose pointers ("詳細は <ref> を参照。")
and culturally-loaded one-word labels (例: 気付いたら即追加, 裏取り)
where they anchor a concept more cleanly. Never in normative rule
text or code identifiers.

## Frozen invariants (read once per session)

- **Release is user-only (ADR-0156)**: never autonomously tag, publish, or
  cut over to a release. Tag / publish / version come only from an explicit
  user message. (The v2 build campaign — Phase 16 完成形 — is complete; the
  project is in maintenance. v2 is on `main`; v1 frozen at v1.11.1.)
- **ROADMAP §18 amendment**: routine `[x]` flips + SHA backfills + next
  phase table expansion = no ADR. Deviation in §1 / §2 (P/A) / §4
  (architecture / Zone / ZirOp) / §5 (layout) / §9 phase scope/exit /
  §11 / §14 forbidden list = file `.dev/decisions/NNNN_<slug>.md` per
  §18.2 FIRST. **Carve-out (ADR-0132)**: re-sequencing/re-scoping the
  ROADMAP because a phase's exit/scope references genuinely-later-phase
  work (§18.1 first bullet) is **AUTONOMOUS** — file the ADR + §18.2
  four-step + forward-ref each deferred item to its true phase, and
  proceed without stopping (no user-flip). Default posture =
  autonomous-with-ADR; surface only for bucket-2/3 genuine blocks.
- **3-host gate**: Mac aarch64 (foreground) + `ubuntunote` Linux x86_64
  (background, **always** `test-all` per ADR-0076 D6) + `windowsmini`
  (background, **BATCHED** per ADR-0076 **D8** — run via
  `should_gate_windows.sh` once per batch: **≥6 commits if the batch
  touched ABI/calling-convention/frame-layout paths, else ≥12**; ABI-risk
  no longer an immediate trigger. heisenbug-aware, NOT per-turn). **Chain
  MANY chunks per turn (larger granularity) on Mac+ubuntu; NEVER poll-wait
  on windows** — kick it in the background when the batch fires, keep
  chaining, verify its verdict at the next Step 0.7. windowsmini
  phase-boundary reconcile remains the strict A13-merge gate. OrbStack
  retired per ADR-0067 (D-134); scratch only. **SUSPENDABLE (ADR-0174,
  user-directed 2026-06-07)**: after a windowsmini-hardening campaign
  reaches full green, `should_gate_windows.sh --suspend` (sentinel
  `.dev/windows_gate_suspended`) drops the inner loop to a **2-host gate
  (Mac+ubuntu)**; `--resume` before any `main` merge / Win64-risk diff.
  A13 strict-3-host merge gate UNCHANGED.
- **Context budget**: the **1M** window is in effect (the prior 200K pin
  `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` was removed 2026-05-31 — it made the
  window hit 100% fast and the squeeze, not the working set, was the felt
  pain). The real levers are **structural, not a window cap**: (1) lean
  auto-loaded rules — `.claude/rules/*.md` are injected IN FULL by their
  `paths:` frontmatter glob, so each carries only the load-bearing
  invariant + enforcement pointer; verbose rationale lives in
  `.claude/references/*.md` (no frontmatter → on-demand read only); (2)
  fork big reads/surveys to subagents AND have them return ≤30-line
  summaries (the report returns into main context too); (3) keep
  `.dev/handover.md` current (SessionStart + `PostCompact` re-inject it
  via `scripts/print_handover_brief.sh`). Unused MCP plugins off in
  `settings.local.json`. Full rationale: `.claude/references/context_budget.md`.

## Working agreement (short list)

- TDD: red → green → refactor.
- **Design priority (ADR-0153)**: the bar is clean final design +
  full-featured + 100% spec + **lightweight-yet-fast**. A *measured*
  structural deficiency in one of those — esp. a v1-parity miss (§1.2)
  rooted in a deliberate v2 simplification — **schedules a rework, not a
  defer-past-v0.1.0** (v0.1.0 is not urgent; correctness + design
  quality gate, not the date). Run it as a correctness-first
  **rework campaign** per
  [`continue/REWORK.md`](skills/continue/REWORK.md) (I+II hard
  gates before redesign code), WITHIN single-pass P3/P6 (no optimising
  tier). Never over correctness.
- Step 0 Survey before each task per
  [`textbook_survey.md`](rules/textbook_survey.md). No copy-paste
  from v1 per [`no_copy_from_v1.md`](rules/no_copy_from_v1.md).
- Commit at natural granularity. `private/` is gitignored agent scratch
  (not authoritative; promote to ROADMAP/ADR/lesson/debt/handover if it
  matters).
- Subagent fork for: Step 0 surveys, large test logs (>200 lines),
  cross-codebase searches (>5 files), audit/simplify/security-review
  fan-out.
- Debt + lessons live in git: [`.dev/debt.yaml`](../.dev/debt.yaml) (ledger,
  refresh per `/continue` Step 0.5), [`.dev/lessons/`](../.dev/lessons/)
  (re-derivable observations, INDEX.md is the keyword index for Step
  0.4).
- Don't paper over absences. Walk the 3-step procedure in
  [`extended_challenge.md`](rules/extended_challenge.md) before
  declaring something missing or shipping a SKIP-X workaround.
- Bound every backgrounded long-runner with `timeout` per
  [`orphan_prevention.md`](rules/orphan_prevention.md). The
  remote gates self-guard via `scripts/orphan_guard.sh` (reap + bound);
  compounds with Microsoft Defender's `.zig-cache`/`zig-out` scan
  (cf. D-028) so orphans hurt double here.

## Skills

- [`continue`](skills/continue/SKILL.md) — resume context + the
  per-task TDD loop (red→green→refactor). Triggers on "続けて" / "/continue"
  / "resume". **Maintenance mode** (post-campaign): no auto-loop, no
  self-re-arm, no direct-to-`main` push — work on a `develop/<slug>` branch
  → PR. The `LOOP/GATE/RESUME/REWORK/STOP_BUCKETS` sub-docs are the retired
  campaign machinery, kept as historical reference.
- [`audit_scaffolding`](skills/audit_scaffolding/SKILL.md) —
  adaptive audit (staleness / bloat / lies / debt+lessons coherence /
  extended-challenge consistency) across CLAUDE.md, `.dev/`, `.claude/`,
  `scripts/`.
- [`debug_jit_auto`](skills/debug_jit_auto/SKILL.md) — SEGV /
  miscompile / runtime-crash investigation toolkit.

## Layout (pointer)

`src/` Zig source (parse / validate / ir / runtime / instruction /
feature / engine / interp / wasi / api / cli / diagnostic / support /
platform — shape per ADR-0023 + ADR-0024).
`include/` public C headers. `build.zig` build script. `flake.nix` Nix
dev shell pinned to Zig 0.16.0.
`.dev/` ROADMAP + handover + debt + lessons + decisions + phase_log +
setup docs.
`.claude/` settings, skills, rules, output styles.
`scripts/` gate, zone_check, file_size_check, bench, run_remote_*, ...
`test/` unified `zig build test-all` aggregator + per-layer suites.
`bench/` append-only benchmark history. `private/` gitignored scratch.

## Build & test (pointer)

```sh
zig build               # compile
zig build test          # unit tests
zig build test-spec     # spec testsuite
zig build test-all      # all enabled layers
zig fmt src/            # format
```

3-host invocation discipline in
[`GATE.md`](skills/continue/GATE.md).

Realworld `.wasm` fixtures are generated on the **Mac host only** via
`nix develop .#gen` (emcc / tinygo / rustc-wasm / go / clang+lld, pinned
in `flake.nix`); the committed `.wasm` runs on the test hosts through the
Zig-built edge-runner (no toolchain there). See
[`.dev/toolchain_provisioning.md`](../.dev/toolchain_provisioning.md).

## Pre-commit gate

[`scripts/gate_commit.sh`](../scripts/gate_commit.sh) — full local gate
(`zig build test`, `zone_check`, `file_size_check`, `spill_aware_check`,
`zig build lint`). `/continue` runs per-task; manual commits call before
`git commit`.

Per-chunk parallel host gate = 2-host (Mac + ubuntunote). windowsmini
reconciliation = phase boundary. Strict 3-host `test-all` = A13 merge
gate (any `main` push); automated by `scripts/gate_merge.sh`.

## References

- [`.dev/ROADMAP.md`](../.dev/ROADMAP.md) — single source of truth (mission,
  principles, phase plan). Conflicts → ROADMAP wins.
- [`.dev/handover.md`](../.dev/handover.md) — current state (≤ 100 lines,
  replaced not appended). Optional `## Active bundle` section per
  ADR-0118 D6.
- [`.dev/debt.yaml`](../.dev/debt.yaml) — debt ledger.
- [`.dev/lessons/`](../.dev/lessons/) — observational notes (see INDEX.md).
- [`.dev/decisions/`](../.dev/decisions/) — ADRs (load-bearing deviations
  only).
- [`.dev/phase_log/`](../.dev/phase_log/) — sub-chunk records (§18.3).
- [`.dev/proposal_watch.md`](../.dev/proposal_watch.md) — Wasm proposal
  tracking (quarterly).
- [`ADR-0118`](../.dev/decisions/0118_meta_loop_consolidation.md) — meta-
  ADR for the rule/skill consolidation + bundle-mode that shaped the
  current loop scaffolding.
