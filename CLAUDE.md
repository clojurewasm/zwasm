# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> Pointers only — detailed plans live in [`.dev/ROADMAP.md`](.dev/ROADMAP.md),
> runnable procedures in [`.claude/skills/`](.claude/skills/), the
> autonomous loop in [`.claude/skills/continue/SKILL.md`](.claude/skills/continue/SKILL.md).

## Identity

**Project name (in all docs and the published artifact): `zwasm`.**
Binary / package: `zwasm`.

This branch is a ground-up redesign of zwasm on top of v1 git history
(commit 517cc5a, charter):

- Working dir: `~/Documents/MyProducts/zwasm_from_scratch/` (distinct
  from `~/Documents/MyProducts/zwasm/`, the read-only v1 reference clone).
- Branch: `zwasm-from-scratch`. **Never push to `main`**; push to
  `zwasm-from-scratch` only with explicit user approval (or autonomously
  inside `/continue`). `--force` always forbidden.
- v1 ABI compatibility is out of scope; `docs/migration_v1_to_v2.md`
  ships at v0.1.0 release.

Read-only reference clones: `~/Documents/OSS/` + `zwasm/` (v1) +
`ClojureWasmFromScratch/`. Full list at
[`.dev/reference_clones.md`](.dev/reference_clones.md); mirrored in
`additionalDirectories` setting. Never edit or commit from these
paths. Pre-redesign investigation: `~/zwasm/private/v2-investigation/`.

## Language policy

Public project. **English by default** for code, comments, identifiers,
commit messages, README, ROADMAP, ADRs, `.dev/`, `.claude/`, all config.
**Japanese** for chat replies only. Enforced by
[`.claude/output_styles/japanese.md`](.claude/output_styles/japanese.md)
+ SessionStart hook.

**Bilingual exception**: meta-prose pointers ("詳細は <ref> を参照。")
and culturally-loaded one-word labels (例: 気付いたら即追加, 裏取り)
where they anchor a concept more cleanly. Never in normative rule
text or code identifiers.

## Frozen loop invariants (read once per session)

- **`/continue` re-arm = `ScheduleWakeup(delaySeconds=60,
  prompt="/continue")`** — literal `60` is harness runtime floor
  (clamp `[60, 3600]`). The tool description's "default 1200-1800s"
  does NOT apply here. Full reasoning:
  [`.claude/skills/continue/LOOP.md`](.claude/skills/continue/LOOP.md)
  §"Self-perpetuation".
- **ROADMAP §18 amendment**: routine `[x]` flips + SHA backfills + next
  phase table expansion = no ADR. Deviation in §1 / §2 (P/A) / §4
  (architecture / Zone / ZirOp) / §5 (layout) / §9 phase scope/exit /
  §11 / §14 forbidden list = file `.dev/decisions/NNNN_<slug>.md` per
  §18.2 FIRST.
- **3-host gate**: Mac aarch64 + `ubuntunote` Linux x86_64 (SSH) +
  `windowsmini` SSH. Per-chunk autonomous = 2-host (Mac + ubuntunote)
  per ADR-0049 + ADR-0067. windowsmini = phase boundary. OrbStack
  retired from per-chunk gate per ADR-0067 (D-134); scratch only.

## Working agreement (short list)

- TDD: red → green → refactor.
- Step 0 Survey before each task per
  [`textbook_survey.md`](.claude/rules/textbook_survey.md). No copy-paste
  from v1 per [`no_copy_from_v1.md`](.claude/rules/no_copy_from_v1.md).
- Commit at natural granularity. `private/` is gitignored agent scratch
  (not authoritative; promote to ROADMAP/ADR/lesson/debt/handover if it
  matters).
- Subagent fork for: Step 0 surveys, large test logs (>200 lines),
  cross-codebase searches (>5 files), audit/simplify/security-review
  fan-out.
- Debt + lessons live in git: [`.dev/debt.md`](.dev/debt.md) (ledger,
  refresh per `/continue` Step 0.5), [`.dev/lessons/`](.dev/lessons/)
  (re-derivable observations, INDEX.md is the keyword index for Step
  0.4).
- Don't paper over absences. Walk the 3-step procedure in
  [`extended_challenge.md`](.claude/rules/extended_challenge.md) before
  declaring something missing or shipping a SKIP-X workaround.

## Skills

- [`continue`](.claude/skills/continue/SKILL.md) — autonomous resume +
  per-task TDD loop. Triggers on "続けて" / "/continue" / "resume".
  Stop conditions in
  [`STOP_BUCKETS.md`](.claude/skills/continue/STOP_BUCKETS.md).
- [`audit_scaffolding`](.claude/skills/audit_scaffolding/SKILL.md) —
  adaptive audit (staleness / bloat / lies / debt+lessons coherence /
  extended-challenge consistency) across CLAUDE.md, `.dev/`, `.claude/`,
  `scripts/`.
- [`debug_jit_auto`](.claude/skills/debug_jit_auto/SKILL.md) — SEGV /
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
[`GATE.md`](.claude/skills/continue/GATE.md).

Realworld `.wasm` fixtures are generated on the **Mac host only** via
`nix develop .#gen` (emcc / tinygo / rustc-wasm / go / clang+lld, pinned
in `flake.nix`); the committed `.wasm` runs on the test hosts through the
Zig-built edge-runner (no toolchain there). See
[`.dev/toolchain_provisioning.md`](.dev/toolchain_provisioning.md).

## Pre-commit gate

[`scripts/gate_commit.sh`](scripts/gate_commit.sh) — full local gate
(`zig build test`, `zone_check`, `file_size_check`, `spill_aware_check`,
`zig build lint`). `/continue` runs per-task; manual commits call before
`git commit`.

Per-chunk parallel host gate = 2-host (Mac + ubuntunote). windowsmini
reconciliation = phase boundary. Strict 3-host `test-all` = A13 merge
gate (any `main` push); automated by `scripts/gate_merge.sh`.

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — single source of truth (mission,
  principles, phase plan). Conflicts → ROADMAP wins.
- [`.dev/handover.md`](.dev/handover.md) — current state (≤ 100 lines,
  replaced not appended). Optional `## Active bundle` section per
  ADR-0118 D6.
- [`.dev/debt.md`](.dev/debt.md) — debt ledger.
- [`.dev/lessons/`](.dev/lessons/) — observational notes (see INDEX.md).
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing deviations
  only).
- [`.dev/phase_log/`](.dev/phase_log/) — sub-chunk records (§18.3).
- [`.dev/proposal_watch.md`](.dev/proposal_watch.md) — Wasm proposal
  tracking (quarterly).
- [`ADR-0118`](.dev/decisions/0118_meta_loop_consolidation.md) — meta-
  ADR for the rule/skill consolidation + bundle-mode that shaped the
  current loop scaffolding.
