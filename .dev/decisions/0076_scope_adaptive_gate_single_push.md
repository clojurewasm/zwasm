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

> **D6 (2026-06-05) scopes this table to the FOREGROUND Mac gate only.**
> The background ubuntu gate is unconditionally `test-all` and no longer
> consults the classifier — see D6 below.

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

### D6 — Background ubuntu gate is unconditionally `test-all` (2026-06-05 amend; D-262)

D1's scope-adaptive table was authored when ubuntu was **waited on**
(original D1+D3: Mac test → push → **ubuntu wait** → next chunk). The
narrow-`test` ubuntu option existed to cut that wait (Alternative A:
~5.8 h saved across §9.12-B). **D5-b moved the ubuntu kick to per-turn
background — the loop no longer waits on it.** With the wait gone, the
sole justification for narrow-scope ubuntu evaporated, while the cost of
getting the scope wrong stayed real: D-260 shipped x86_64 SIMD emit bugs
marked "RESOLVED" because an emit chunk's ubuntu kick was eyeballed to
narrow `test` (which skips the spec/edge SIMD runners) and "x86_64
cross-COMPILE" was mistaken for x86_64-RUN (lesson
`2026-06-04-cross-compile-is-not-cross-run`); the bugs surfaced only at
the phase-boundary windowsmini `test-all`.

**Decision: the background ubuntu gate runs `test-all` unconditionally.**
`classify_chunk_scope.sh` now drives ONLY the **foreground Mac** gate —
where narrow `test` still buys real loop latency, because the loop blocks
on it (Step 5). The async ubuntu gate no longer consults the classifier:
every per-chunk/per-turn kick is `bash scripts/run_remote_ubuntu.sh
test-all` (its no-arg default), so there is no scope decision left to get
wrong. Net:

- **Mac (foreground, waited-on)**: scope-adaptive per D1 (unchanged).
- **ubuntu (background, not waited-on)**: always `test-all` — x86_64-RUN
  of the full spec + edge + realworld corpora every cycle.

This reverses the **ubuntu half** of Alternative A (and Alternative B's
"substrate skips `-spec`/`-realworld`"): both were priced against a wait
that D5-b removed. The residual cost is background ubuntu CPU + a wider
in-flight deferral window — absorbed by D3/D5-b's existing "OK-line-absent
= still running, re-check next cycle" tolerance, and by the fact that
emit-heavy turns (where coverage matters most) are slow enough for the
test-all to finish. Safety (uniform x86_64-RUN coverage, no eyeballed-scope
foot-gun) beats background machine time. **win64-RUN stays phase-boundary**
(windowsmini; ADR-0049/0067) — D6 closes the x86_64-RUN half; the win64
half remains a known, accepted phase-boundary gate. **[Superseded by D7 —
win64 now joins the per-turn background gate.]**

### D7 — Win64 (windowsmini) joins the per-turn background gate, heisenbug-aware (2026-06-05 amend; user-directed)

D6 closed the x86_64-RUN half but left **win64-RUN at phase-boundary only**
(ADR-0049/0067 + the windowsmini-skip policy). 2026-06-05 that gap bit exactly as
D-260/D-262 did for x86_64: a manual windows `test-all` — run only because we were
3-host-checking the WASI-program wiring — surfaced a **Win64-only SIMD JIT crash**
(`simd_bit_shift`, exit 3, intermittent) that had accumulated undetected, plus a
Win64 MSVC-`link.exe` + rustc-`.exe`-suffix gap in the rust_host step. User
directive: "win64 固有バグは回さないと積もる — 根本的に対処".

**Decision: HONOR `should_gate_windows.sh` — windows runs OCCASIONALLY (たまに), on a
cadence, NOT every turn (windows is too slow for per-turn) and NOT phase-boundary-only
(too rare → bugs accumulate).** The right cadence ALREADY EXISTS in
`scripts/should_gate_windows.sh`: gate when the turn's diff (since the last
windows-tested SHA) hits a **Win64-risk path** (`x86_64/{abi,op_call,prologue}.zig`,
`shared/{jit_abi,entry}.zig`, `build.zig`, `run_remote_windows.sh`) OR when **≥4
commits** have landed without a windows run; else defer. The bug was the *policy*
(ADR-0049 + the skip-note) **IGNORING** this script ("must NOT fire
run_remote_windows regardless of should_gate_windows.sh's output"). D7 flips that:
Step 6+7 runs `should_gate_windows.sh`; **exit 0 → kick `run_remote_windows.sh
test-all` in background** (alongside the always-on ubuntu kick); after a green windows
verify, `should_gate_windows.sh --record`. Win64 is thus exercised every few
commits / on every ABI-risk turn — early enough to stop accumulation, light enough
to respect windows' slowness.

**Heisenbug-aware verification (the Win64-specific half).** Win64 is heisenbug-prone
(FP-walk / X29-sentinel / RSP-parity lineage). Unlike ubuntu (auto-revert on red,
D3), a **windows red is NOT auto-reverted**: re-run the failing exe ONCE.
- **Reproduces (deterministic)** → real Win64 divergence: file a debt row + fix;
  revert the turn only if a same-turn Win64-emit change is clearly the cause.
- **Passes on re-run (intermittent)** → heisenbug flake: `track_heisenbug.sh <name>
  segv` + proceed; do NOT revert (an intermittent crash ≠ a deterministic RED).
So windows is a regularly-exercised MONITORING gate: deterministic reds act, flakes
are tracked (investigation_discipline.md §2 discharge protocol).

**Amends** ADR-0049/0067 (windowsmini was phase-boundary-deferred) + the
windowsmini-skip policy: windows is no longer phase-boundary-only NOR ignored — the
loop HONORS `should_gate_windows.sh`'s cadence (the early-warning monitoring gate).
The phase-boundary windows reconcile remains the *strict* (deterministic, A13-merge)
gate; D7 adds the every-few-commits cadence between boundaries.

**Cost**: windows runs only on the cadence (ABI-risk diff OR ≥4 commits), background
→ no loop wall-clock; far cheaper than per-turn, far safer than phase-boundary-only.
The deferral window (windows slower than ubuntu) is absorbed by the "OK-line-absent
= still running, re-check" tolerance.

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

### D8 — Windows gate BATCHED (bigger threshold); chain many chunks, never poll-wait on windows (2026-06-06 amend; user-directed)

**Problem.** Under D7 the loop ran windowsmini on every ABI-risk turn OR
≥4 commits. In practice that made the loop **poll-wait on windows too
often** — each windows run is the slow host (~minutes), and the loop kept
ending turns / re-arming to check its verdict instead of pressing ahead
on Mac+ubuntu. The user-felt pain was iteration latency, not coverage.

**Decision.** Windows verification is **batched**, decoupling iteration
speed from the slow host:

1. **Bigger cadence threshold** (`should_gate_windows.sh`): run
   windowsmini once per BATCH — **≥6 commits if the batch touched
   ABI/calling-convention/frame-layout paths, else ≥12 commits**. ABI-risk
   is **no longer an immediate per-commit trigger**; it only lowers the
   batch size. (Was: immediate on any ABI-risk diff OR ≥4.)
2. **Chain MANY chunks per turn, larger granularity.** Mac (foreground)
   + ubuntu (background, every turn) are the fast iteration loop; do
   several chunks' worth of work per turn, push once. **Never poll-wait
   on windows** — kick it in the background when the batch threshold
   fires, keep chaining, and verify its verdict opportunistically at the
   next Step 0.7 whenever it lands.
3. **Unchanged**: ubuntu = always per turn (D6); heisenbug-awareness +
   no-auto-revert on windows (D7); Step 0.7 verdict verification; the
   A13-merge strict 3-host gate; phase-boundary windowsmini reconcile.

**Trade-off (accepted, user-directed).** A Win64-specific bug now
surfaces after up to ~12 commits (vs ~4), so bisection spans a bigger
batch. The heisenbug streak + Step 0.7 + the strict A13/phase-boundary
gates remain the safety net; the iteration-speed win dominates for the
Phase 16 完成形 debt-repayment cadence (mostly Mac/x86_64-verifiable work).

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
| 2026-05-30 | `b39689e1` | D5 amend — in-turn chunk chaining + per-turn ubuntu batch (widens D3 one-chunk→one-turn) + gate-once + bigger-chunk default (user throughput directive). |
| 2026-06-05 | `5471e5fb` | D6 amend — background ubuntu gate unconditionally `test-all` (classifier drives Mac foreground only); closes D-262 x86_64-RUN coverage gap (justification removed by D5-b's no-wait ubuntu). |
| 2026-06-05 | `72c4aaf8` | D7 amend — loop HONORS `should_gate_windows.sh` cadence (windows runs たまに: ABI-risk diff OR ≥4 commits, NOT per-turn — windows too slow; NOT phase-boundary — too rare), heisenbug-aware (no auto-revert); closes the win64 accumulation gap, user-directed. |
| 2026-06-06 | _(this)_   | D8 amend — windows BATCHED (≥6 commits if ABI-risk in batch, else ≥12; ABI-risk no longer immediate); chain many chunks/turn, never poll-wait on windows. Iteration-speed directive, user-directed. |
