# 0076 — Scope-adaptive per-chunk gate + single-push cycle + deferred ubuntu verification

- **Status**: Accepted
- **Date**: 2026-05-19
- **Author**: Shota Kudo
- **Tags**: process, loop, gate

## Context

Two cost observations from the §9.12-B autonomous loop:

1. **`zig build test-all` is the unconditional per-chunk gate.** B53
   (substrate-only — new `EmitCtx` struct + inert init, no fn body
   change) spent ~10 minutes on ubuntu `test-all` exercising no new
   behaviour. The B53 / B54 cycle pair spent more wall-clock on
   ubuntu test waits than on every other step combined.
2. **Per-chunk pipeline is serial.** Today's order is
   Mac test → source commit → push → **ubuntu test wait** →
   handover commit → push (= 2 pushes per chunk; the loop is pinned
   to ubuntu's wall-clock; bench-CI bot lands a `bench(ci): record`
   commit between the two pushes, forcing a rebase per chunk).

§9.12-B has ~70 remaining chunks; the cost compounds.

## Decision

Adopt three coupled disciplines for the autonomous loop. None of them
relaxes spec conformance — they reorder when verification happens, not
what gets verified.

### D1 — Scope-adaptive gate

Chunk scope is mechanically classified by
`scripts/classify_chunk_scope.sh`, which reads `git diff --stat HEAD`
+ `git diff HEAD` and prints one of:

| Class       | Gate             | Trigger heuristic                                                       |
|-------------|------------------|-------------------------------------------------------------------------|
| `substrate` | `zig build test` | New / changed files are struct defs + init sites + imports only         |
| `logic`     | `zig build test-all` | New `pub fn emit*` / dispatch arm change / new per-op file under `ops/` |
| `cohort`    | `zig build test-all` | ≥ 5 ops touched (file count under `ops/*` directory)                    |
| `unclear`   | `zig build test-all` (default) | The above heuristics didn't fire; safe fallback              |

LOOP.md does **not** maintain the judgement table in prose — the
script *is* the rule (mirroring `gate_commit.sh` / `zone_check.sh` /
`file_size_check.sh`). When the heuristic needs updating (new file
shape, new layer), the script is the single edit site.

### D2 — Single-push cycle

Source commit and handover commit land back-to-back locally, then
**one** `pull --rebase --autostash + push` fires. The bench-CI bot's
`bench(ci): record <sha>` commit gets rebased exactly once per chunk
instead of twice.

### D3 — Deferred ubuntu verification

ubuntu test starts in `run_in_background` **after** the push (= against
the just-pushed commit) and is **not** waited on by the current
cycle. The result is verified at the next cycle's Resume Procedure
Step 5c — a mechanical `tail -3 /tmp/ubuntu.log` check for the
`[run_remote_ubuntu] OK (HEAD=<sha>)` line whose SHA matches
`HEAD~1`. If the prior cycle's ubuntu FAILed, the current cycle
reverts the last 2 commits (`git reset --mixed HEAD~2`), preserves
the diff in the worktree, and switches to fix mode.

The verification deferral is **one chunk** wide — the loop never
gets more than one chunk ahead of ubuntu. **(Widened to one
*turn* (N chunks) by D5 — see below.)**

### D4 — pre-commit + pre-push hook slim-down (2026-05-20 amend)

The original D1+D2+D3 left `.githooks/pre-commit` and
`.githooks/pre-push` unchanged — both invoked `scripts/gate_commit.sh`,
which internally runs `zig build test` (~30 s) and `zig build lint`
(~10 s). Per-chunk this was pure duplication: the loop's Step 4
(lint) and Step 5 (test) already ran them once before commit.
Per-chunk cost: ~30 s pre-commit + ~30 s pre-push test re-run +
~10–30 s ratchet = ~60–90 s of hook overhead on top of network
and the actual gate.

Resolution:

- **`scripts/gate_commit.sh --fast`** new flag — skips `zig build
  test` + `zig build lint` + **`zone_check.sh --gate`**. Still
  runs `zig fmt --check`, `file_size_check`, `check_skip_adrs`,
  `check_adr_history`, info-level checks (`libc_boundary`,
  `fallback_patterns`, `invariant_comments`, `lesson_citing`).
- **`zone_check.sh` deferred to `audit_scaffolding`** —
  measured ~100 s per invocation due to per-file
  awk+grep+cd subshell forking; the rule itself stays
  load-bearing but per-commit enforcement at this cost is
  not. Manual `gate_commit.sh` (no flag) still runs it as
  the safety net for non-loop commits.
- **`.githooks/pre-commit`** invokes `gate_commit.sh --fast` (per
  D4). The loop's Step 4 + Step 5 own test + lint. Manual commits
  can still run `bash scripts/gate_commit.sh` (no flag)
  explicitly for the full pre-ADR-0076 suite as a safety net.
- **`.githooks/pre-push`** no longer invokes `gate_commit.sh` at
  all. The only retained checks are `check_subrow_exit --gate`
  and `check_skip_impl_ratchet --gate`, both cheap when they
  have nothing to do. Rationale: every commit has already passed
  pre-commit; re-running the same static checks at push time
  catches nothing new.
- **`commit.gpgsign` local-disable** — the local-repo override
  `git config commit.gpgsign false` is set on this clone (the
  user's global config has SSH-key sign on; for this repo's
  autonomous-loop cadence the per-commit signing cost is not
  carrying its weight — the `main` merge gate is the
  authentication surface). This is a per-clone setting; new
  clones inherit the global default unless re-overridden.

Cost: per-chunk hook overhead drops from ~130 s (measured) to
**~30 s** (zone_check skip = -100 s; test/lint skip = -40 s
already counted in D1+D2+D3; commit.gpgsign off = -1-2 s).
Net loop acceleration ~1.5 min per chunk × ~70 remaining
chunks in §9.12-B = ~105 min saved.

Safety: `--no-verify` skip remains forbidden by ROADMAP §14.
The `main` merge gate (`scripts/gate_merge.sh`) is unchanged
and still runs the full 3-host `test-all`. The loop's Step 4
+ Step 5 are the load-bearing test+lint sites under this
discipline — if either silently skipped, broken code reaches
origin (recovered at next cycle's Step 0.7).

### D5 — In-turn chunk chaining + per-turn ubuntu batch (2026-05-30 amend)

D1–D3 were written as **one chunk = one `/continue` turn = one
ubuntu kick = one re-arm**. In practice that paid, *per chunk*, a
60 s `ScheduleWakeup` idle gap + a full Resume Procedure (handover
re-read, framing grep, Step 0.7, git status) + ubuntu-cadence
friction. For small chunks the overhead-to-work ratio was poor
(cyc228–230: 3 cycles, 1 code chunk). User directive 2026-05-30:
raise per-turn throughput. A `/continue` **turn** may now execute
**N chunks back-to-back** before ending:

- **D5-a — In-turn chaining.** After a chunk's commit pair lands,
  do NOT end the turn / re-arm. Proceed directly to the next
  chunk's Step 0 in the same turn, keeping working context (skip
  the redundant inter-chunk Resume). End the turn (→ push, kick,
  re-arm) only at a natural pause: immediately-actionable work
  exhausted, an approaching context-fill / auto-compact boundary,
  a hard-gate / bucket-3 / user touchpoint, or a deliberate flush.
  The `ScheduleWakeup(60)` re-arm is the **unattended-resume
  safety net fired at turn end**, NOT a per-chunk throttle. The
  frozen invariant "re-arm = `ScheduleWakeup(60)`" is unchanged —
  only *when* it fires moves from per-chunk to per-turn.
- **D5-b — Per-turn ubuntu batch (widens D3).** Commit pairs
  accumulate locally through the turn; **one** `pull --rebase
  --autostash + push` + **one** ubuntu kick fire at turn end,
  against the turn's final HEAD. Step 0.7 verifies that final
  HEAD. The deferral window widens from D3's "one chunk" to "one
  turn (N chunks)". On FAIL, revert the **whole turn's commits**
  to the last ubuntu-verified HEAD (`git reset --mixed
  <verified-sha>`), then bisect/fix. Trade-off: coarser failure
  attribution; acceptable because each chunk still passes the
  local Mac gate (Step 5) before its commit, so ubuntu-red is an
  arch-divergence signal (historically rare) and the turn batch
  is bisectable. (D3's per-chunk-push form remains valid for a
  one-chunk turn.)
- **D5-c — Gate once per commit.** The pre-commit hook
  (`gate_commit.sh --fast`) + the loop's single Step 5 `zig build
  test` ARE the gate. Do not additionally run `zig build test` /
  `zig build lint` / `file_size_check` standalone before the
  commit — that re-pays D4's eliminated duplication. One test
  pass per chunk; lint at Step 4 of a code-bearing chunk, re-run
  only if a later chunk touches lint surface.
- **D5-d — Bigger-chunk default.** Prefer a complete unit (both
  arches of an emit, harness + first feature together) over atomic
  per-step splits. Reinforces the chunk-granularity "when in doubt,
  bundle" rule. The `architectural` 3-cycle cap still applies; D5
  raises the floor of per-turn ambition, not the cap.

Net: a green multi-chunk turn pays the 60 s gap + Resume + ubuntu
round-trip **once per turn** instead of once per chunk. A red turn
loses N chunks of forward motion at the next Step 0.7 instead of 1
— the priced-in cost of the batch.

## Alternatives considered

### Alternative A — Keep test-all per chunk

Status-quo. Rejected: §9.12-B has ~70 remaining chunks × ~10 min
ubuntu test-all = ≈11.6 h pure ubuntu wait. Even a 50% scope-adaptive
hit rate saves ≈5.8 h.

### Alternative B — Skip ubuntu entirely on substrate chunks

Tempting (substrate bugs would surface on Mac `test`). Rejected:
ubuntu catches x86_64-specific issues that Mac aarch64 can't see
(stack alignment off-by-N, x86_64 codegen miscompile, OS-specific
syscall numbers). Substrate chunks legitimately need ubuntu — they
just don't need `-spec` / `-realworld` corpora on top of `test`.

### Alternative C — Branch per chunk + verify on PR

Incompatible with the autonomous-loop model. Rejected.

### Alternative D — Block on ubuntu before next chunk's Step 0

Status-quo's gating discipline. Rejected: the cost item (1) is
exactly the wall-clock penalty of this block.

## Consequences

### Positive

- Substrate / refactor chunks land ~5x faster (≈2 min vs ≈10 min).
- Push count halves; rebase-against-bench-bot incidence halves.
- ubuntu wait becomes background; the loop starts the next chunk's
  Step 0 immediately after push.
- The `classify_chunk_scope.sh` heuristic is single-site-editable;
  per-class behaviour evolves without LOOP.md prose churn.

### Negative

- Step 5c FAIL means reverting 2 commits (source + handover). Handled
  by `git reset --mixed HEAD~2` + re-staging.
- ubuntu-deferred-verification means a failing chunk lands on origin
  briefly (≈1 chunk window). The `zwasm-from-scratch` branch is the
  development branch (push is autonomous; no PR gate); the merge gate
  (`scripts/gate_merge.sh` per CLAUDE.md "Pre-commit gate") still
  blocks any `main` push on the strict 3-host `test-all`.
- `classify_chunk_scope.sh` maintenance burden: new file shapes need
  heuristic updates. The default fallback (`test-all`) absorbs slips
  safely.

### Neutral / follow-ups

- ADR-0049 (windowsmini per-chunk defer) was the spiritual predecessor:
  this ADR generalises that policy to ubuntu-and-Mac scope. The
  windowsmini phase-boundary reconciliation is unchanged.
- The "1 chunk lookahead" window is conservative. A larger window
  (= the loop runs N chunks ahead of ubuntu) is technically possible
  but rejected for now: revert depth = N is more painful to recover
  from on FAIL.

## Implementation

| Artifact                                                      | Change                                                                                      |
|---------------------------------------------------------------|---------------------------------------------------------------------------------------------|
| `scripts/classify_chunk_scope.sh` (new)                       | `git diff --stat HEAD` + heuristics → prints `substrate` / `logic` / `cohort` / `unclear`   |
| `.claude/skills/continue/SKILL.md` Resume Step 5c (new)       | Mechanical `tail -3 /tmp/ubuntu.log` check + `git reset` on FAIL                            |
| `.claude/skills/continue/SKILL.md` TDD Step 5                 | Pick scope via `scripts/classify_chunk_scope.sh`; map to gate command                       |
| `.claude/skills/continue/SKILL.md` TDD Step 6 + Step 7        | Merge into single source-then-handover commit pair; single push; ubuntu bg                  |
| `.claude/skills/continue/LOOP.md` "Parallel test gate"        | Rewrite to match D2 + D3                                                                    |
| `scripts/gate_commit.sh` `--fast` flag (D4)                   | Skip `zig build test` + `zig build lint` + `zone_check.sh --gate` when --fast set           |
| `.githooks/pre-commit` (D4)                                   | Invoke `gate_commit.sh --fast`; static checks only                                          |
| `.githooks/pre-push` (D4)                                     | Drop `gate_commit.sh`; keep only `check_subrow_exit` + `check_skip_impl_ratchet`            |
| `.git/config` `commit.gpgsign=false` (D4)                     | Per-clone override of global SSH-sign; cost not carrying weight at autonomous-loop cadence  |

## References

- `.claude/skills/continue/LOOP.md` §"Parallel test gate" — rewritten
- `.claude/skills/continue/SKILL.md` §"Resume procedure" Step 5c — new
- `.claude/skills/continue/SKILL.md` §"Per-task TDD loop" Step 5 — adapted
- ADR-0049 — windowsmini per-chunk defer (spiritual predecessor)
- ADR-0067 — ubuntunote pivot (sets the substrate this ADR builds on)
- §9.12-B / B53 + B54 retrospective (the 2026-05-19 session that
  surfaced the cost)

## Revision history

| Date       | SHA          | Note                                                                                                  |
|------------|--------------|-------------------------------------------------------------------------------------------------------|
| 2026-05-19 | `3063dd0d`   | Initial accepted version (D1 + D2 + D3).                                                              |
| 2026-05-20 | `c1e16f7d` | D4 amend — pre-commit / pre-push hook slim-down (`gate_commit.sh --fast`; pre-push drops gate re-run).|
| 2026-05-30 | `<backfill>` | D5 amend — in-turn chunk chaining + per-turn ubuntu batch (widens D3 one-chunk→one-turn) + gate-once + bigger-chunk default (user throughput directive). |
