---
name: continue
description: Resume context on zwasm and continue the per-task TDD loop (red→green→refactor). Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Orients from the session brief (open PRs / issues + recent commits), runs tests. MAINTENANCE MODE (post-merge): work on a develop/<slug> feature branch off main and open a PR — NO autonomous multi-task loop, NO self-re-arm, NO direct push to main. Release/tag stays user-only.
---

# continue

> **RETIRED CAMPAIGN LOOP → MAINTENANCE MODE (2026-07-01).** v2 shipped to
> `main`; the fully-autonomous single-branch build loop below is HISTORICAL.
> In maintenance, `/continue` = resume context + drive ONE task's TDD cycle
> on a `develop/<slug>` branch → PR to `main`. No overnight self-re-arm, no
> auto-advance across tasks, no direct `main` push. The
> `LOOP/GATE/RESUME/REWORK/STOP_BUCKETS` docs describe the retired campaign
> machinery — read them as reference, not live procedure.

Pick up where the previous session left off, orient from the session brief —
the SessionStart hook prints open PRs, open issues, and the last commits
(`scripts/print_handover_brief.sh`) — and continue the current work item with
a clean red→green→refactor cycle.
Delegate heavy reads/surveys to subagents and keep the working set lean.

## Stop conditions — strict 3-bucket whitelist

> **CAMPAIGN-ONLY.** This governed the autonomous loop's right to keep
> going without asking. `/continue` now drives one task and stops when it
> is done, so nothing here fires — do not act on it. For today's flow see
> §Resume procedure.

Stop ONLY for one of the 3 buckets. Anything else continues.

1. **User intervenes** — explicit message, interrupt, or new directive.
   Silence is NOT intervention.
2. **Genuinely unsolvable** — root cause unclear after investigation
   OR ROADMAP §2/§14 conflict OR required external host provably
   absent (per `extended_challenge.md` definition of "provably").
3. **All forward work user-input-gated AND autonomous prep walked** —
   bucket-3 stop without `ScheduleWakeup` re-arm. See
   [`STOP_BUCKETS.md`](STOP_BUCKETS.md) for the full whitelist + the
   autonomous-prep-paths catalog that must be exhausted first.

**Phase boundaries / "big task" / N-commit milestones / context-fill /
auto-compact / subagent fan-out / push / user silence** — NONE are
stop conditions. Continue.

If unsure whether to stop: **don't**. Full bucket details +
destructive-action policy + non-stop exhaustive list:
[`STOP_BUCKETS.md`](STOP_BUCKETS.md).

## Loop mechanics — see `LOOP.md`

> **CAMPAIGN-ONLY.** There is no self-perpetuation: `/continue` drives one
> task and the turn ends. Do not act on LOOP.md's push or re-arm contract.

Push policy + Self-perpetuation (the `ScheduleWakeup` re-arm contract):
sibling file [`LOOP.md`](LOOP.md). Read once per session at the top of
resume; does not change between iterations.

## Bundle mode (ADR-0118 D6)

> **CAMPAIGN-ONLY.** Bundle state lived in an `## Active bundle` section of
> handover.md, which is FROZEN (2026-08-20, #207 plank 4) — nothing reads or
> writes it now; the deleted `scripts/check_bundle_active.sh` was its validator.
> Multi-session continuity lives in the work's PR / issue. Kept as reference.

When work crosses a session boundary (multi-cycle integration: GC
heap impl, EH-on-JIT integration, regalloc refactor, etc.), use
**bundle mode** to preserve continuity across `/continue` invocations.

Handover.md optionally carries an `## Active bundle` section:

```markdown
## Active bundle

- **Bundle-ID**: 10.E-codegen-IT-1..IT-3
- **Cycles-remaining**: ~3
- **Continuity-memo**: HandlerEntry count + landing_pad_pc fixup table
- **Exit-condition**: try_table fixture compiles + Builder.entries.len > 0 in test
```

Resume procedure Step 1 (below) detects this and **routes to
bundle-next-step** instead of ROADMAP §9 lookup (parallels Step 1a
close-plan override). Bundle close requires the named observable
delta verified — the deleted `scripts/check_bundle_active.sh --close` enforced
this at the close commit. Delta = 0 after planned N cycles → either
continue (extend N) or pivot (handover rewrite + commit chore).

This is the structural defense against atom-rhythm (lesson
`e62db476` — 13 atoms shipped without behavior signal). Bundle mode
makes "multi-cycle integration with continuity" first-class instead
of relying on handover prose.

**Bundle vs debt row — when to pick which** (2026-05-28
clarification per session retrospective):

- **Bundle**: work is being **actively pursued cycle-after-cycle
  RIGHT NOW**. The cycles-remaining + exit-condition contract
  preserves continuity. Use bundle mode for multi-cycle
  investigation chains too (e.g., D-183 → D-184 root-cause
  investigation should have been bundled, not debt-rowed).
- **Debt row**: a noted gap that may or may not be worked soon;
  named structural barrier; discharge predicate clear. Use when
  filing-then-deferring; the row tracks the gap regardless of
  when work resumes.

Test: if you would re-arm `/continue` to immediately work on
this thing next cycle → bundle. If you're noting "this needs
fixing eventually" → debt row.

## Structural rework campaign (ADR-0153)

When a **measured** structural deficiency in a 完成形 dimension
(clean / full-featured / 100% spec / **lightweight-yet-fast**) — a
canonical case: a **v1-parity miss** (§1.2) rooted in a deliberate v2
simplification (e.g. D-265: deterministic-slot regalloc ~2.3× slower
than v1 on loop-locals) — cannot be closed by a quick local fix, open a
**rework campaign**: a multi-bundle, five-phase, correctness-first
redesign. Full mechanics: sibling [`REWORK.md`](REWORK.md).

**Default posture (ADR-0153): schedule the rework, do NOT defer past
v0.1.0.** v0.1.0 timing never gates the decision; correctness + design
quality do (design priority: ADR-0153). The rework stays
WITHIN the inviolable principles — P3/P6 single-pass, no optimising
tier (§1.3/§3.2); staying within them IS the autonomous,
philosophy-aligned judgment (only a *proven* impossibility is the rare
pre-existing bucket-2 = §2 conflict).

**Campaigns are fully AUTONOMOUS** — the loop opens, runs, and closes a
campaign on its own judgment, re-arming every cycle. "Hard gate" orders
the loop's OWN work (I+II before redesign code); it is the loop checking
itself, NEVER a user-intervention point. Stopping to ask "should I
rework / is this phase done?" is the over-babysitting anti-pattern.

Five ordered phases, **I + II are self-enforced gates before any
redesign code**:
**I Investigation** (mechanism confirmed + ROI measured + blast-radius
mapped → findings doc) · **II Correctness-assurance FIRST**
(characterization + **adversarial** tests pin current behaviour so the
rework cannot silently regress — the 正しさ担保 gate; closes D-261-class
"no adversarial test" gaps first) · **III Design** (ADR + anti-regression
invariants + incremental migration) · **IV Implementation** (TDD, full
test net green at EVERY commit, perf measured at milestones) ·
**V Retrospective** (hit the 完成形? new debt? Revision note on the
superseded simplification ADR). Correctness-first ordering (II before
IV) is a hard invariant — never optimise an area you cannot prove you
have not broken.

Detection (campaign-era): handover's `## Active rework campaign` section —
frozen with the file; a maintenance-mode rework is tracked in its own
PR / issue. Bundle mode was used WITHIN a campaign phase for continuity.

## Resume procedure (run on every session pickup)

Outline (full details in [`RESUME.md`](RESUME.md)):

1. **Orient from the session brief** — the SessionStart hook prints open
   PRs, open issues, and the last 3 commits
   (`scripts/print_handover_brief.sh`). The task is what the user asked
   for, or the open PR / issue being continued. `.dev/handover.md` is
   FROZEN (2026-08-20, #207 plank 4; ADR-0212 D1) — a campaign-era
   record, not current state.

   > **CAMPAIGN-ONLY.** The retired steps 1a (close-plan override) /
   > 1b (bundle override) / 1c (rework-campaign override) routed the
   > resume from sections of the then-live handover.md; the file is
   > frozen, so none of them can fire. Details in [`RESUME.md`](RESUME.md).
2. **Read ROADMAP** — Phase Status widget + first `[ ]` row.
3. **git log + status** — clean: proceed. Uncommitted in-flight:
   complete or stash. Local ahead of origin: push immediately.
4. **Step 0.4 — Lesson scan** ([`RESUME.md`](RESUME.md#step-04)).
5. `zig build test`; `test-spec` / differential when the change reaches
   them. Output >200 lines → subagent.
6. **One-sentence status** (last commit + next task). No multi-line
   summary.
7. **Immediately enter TDD loop.** `/continue` itself is the go signal.

**On-demand, not per-resume** (ADR-0212 D2 retired the standing duty; the
procedures stay as capabilities you invoke when they earn their keep):

- **Step 0.5 — Debt sweep + barrier-dissolution**
  ([`RESUME.md`](RESUME.md#step-05)). Run it when you are about to trust a
  `blocked-by` row, or before a broad audit.
  `bash scripts/audit_blocked_by_age.sh` is its mechanized half.
- **Step 0.5b / 0.6 / 0.7** ([`RESUME.md`](RESUME.md#step-05b)) — per-phase
  status scripts, hard-gate prep, and the 3-host `/tmp/{ubuntu,win}.log`
  verification. All three are campaign-era: there are no open phases, no
  registered hard gates, and CI's `ci-required` — not the local farm — is the
  authoritative gate (ADR-0076 D9).

## Per-task TDD loop

**Step 0 defaults to subagent** (Explore, mode "medium"); Step 5 may
delegate large output; rest run in main.

### Chunk granularity (emit chunks)

5–15 ops per chunk for established-pattern emit. **Bundle when ALL**:
same dispatch helper consumer, same handler shape, diff ≤ 800 LOC src
+ 400 LOC test, coordinated boundary semantics. **Split when ANY**:
crosses instruction class, structurally different recipe per variant,
ADR-grade design choice for one variant only, mid-cycle ratchet
> 1200 LOC.

When in doubt: **bundle**. Anti-pattern: "1 op = 1 chunk" for
established-pattern work. Chunk type taxonomy + retrospective examples:
[`LOOP.md`](LOOP.md) §"Chunk types".

### Step 0 — Survey

Default: do Step 0. Skip only when `textbook_survey.md` "When to skip"
criteria hold (refactor/rename/doc-only + no new public API + no new
behaviour). New `encXxx` encoder forfeits skip.

Dispatch one Explore subagent with the textbook-survey brief (200–400
lines: file pointers, key shapes, idioms, divergence highlights from
ROADMAP §2). Summary lands in `private/notes/<phase>-<task>-survey.md`
(optional). See `textbook_survey.md` + `no_copy_from_v1.md`.

**Mid-cycle 裏取り**: `extended_challenge.md` Step 4 — WebFetch /
reference-repo deep read / `private/spikes/<slug>/` throwaway (per
`spike_discipline.md`).

### Step 1 — Plan

Re-open ROADMAP §9.<N> task table when the work maps to a phase row
(maintenance work usually maps to a PR / issue instead).

*(Campaign-only: the close-plan / bundle overrides of Resume steps
1a / 1b routed this lookup through the then-live handover.md.)*

One sentence in chat: smallest red test capturing next behaviour. No
permission needed.

**Deviation watch**: Plan touches §1, §2, §4, §5, §9 scope, §11, §14 →
STOP. File `.dev/decisions/NNNN_<slug>.md` per §18.2 first.
**Carve-out (ADR-0132)**: re-sequencing/re-scoping the ROADMAP because a
phase's exit/scope references genuinely-later-phase work (§18.1 first bullet)
is **AUTONOMOUS** — do NOT stop. Run the §18.2 four-step (edit ROADMAP + ADR +
sync handover + ref in commit), forward-ref each deferred item to its true
phase, and proceed. No user-flip; no recurring "USER-GATED" handover flag.

### Step 2 — Red

Write failing test. Run; confirm red.

### Step 3 — Green

Minimal code to pass. Resist over-design.

### Step 4 — Refactor

While green. Structural improvements only; no behaviour change.

**Debt observation**: smell out of scope?  Mechanical fix (≤ 5 min) →
inline; else **append `now` debt row** to `.dev/debt.yaml`.

**Workaround check**: papered over missing tool/file/capability?
Re-read `extended_challenge.md`; walk 3-step procedure (Confirm →
Self-provision → Document specifically) NOW before Step 5.

**Boundary-fixture check**: diff touched numeric edge / FP corner /
strictness-sensitive comparison / trap condition / regalloc-ABI
invariant → add fixture under `test/edge_cases/p<N>/<concept>/<case>.{wat,wasm,expect}`.
Per `test_discipline.md` §1 stress-axes table.

**Mac-host lint gate** (ADR-0009): `zig build lint -- --max-warnings 0`.
Mac-only; deprecation findings are platform-independent.

### Step 5 — Test gate (scope-adaptive)

Classify: `bash scripts/classify_chunk_scope.sh` → map to gate
command per ADR-0076 D1. Full pipeline + Step 5b bench-delta sub-step
(Phase 8b only):  [`GATE.md`](GATE.md).

### Step 6+7 — Commits (per chunk) + push (per turn) (ADR-0076 D2)

A turn chains **N chunks**; sub-steps 1–3 run per chunk, 6–7 once at
turn end. (The campaign-era "commit pair" — source commit + handover
commit — collapsed to plain commits when handover.md froze: #207
plank 4. Session state = the branch and its PR.)

**Per chunk** (every chunk in the turn):

1. **Source commit**. `git add <files>; git commit -m "<type>(<scope>): <line>"`.
   Pre-commit gate (`gate_commit.sh --fast`) runs — that IS the
   commit check; do NOT additionally run `zig build test` / `lint` /
   `file_size_check` standalone (D5-c; Step 5 already ran test once).
   Never `--no-verify` (§14 forbidden).
2. **Mark `[x]` for completed task in ROADMAP §9.<N>** when the work
   maps to a phase row. SHA stays bare; batch-backfilled at phase
   close. **§18 self-check** (PreToolUse hook re-prints): routine `[x]`
   flip + SHA backfill = no ADR. Touching §1/§2/§4/§5/§9
   scope/§11/§14 = deviation; file ADR first.
3. **Append `.dev/debt.yaml` + lessons** as needed.

→ **Then CHAIN (D5-a; D8 reinforces — chain BIG)**: go straight to the
next chunk's Step 0 in the **same turn**, keeping working context. Do NOT
push/kick/re-arm between chunks. **Default to MANY chunks per turn (larger
granularity)** — Mac+ubuntu are the fast loop; pack several debt-items /
slices into one turn before flushing. End the turn only at a natural
pause: immediately-actionable work exhausted, approaching context-fill /
auto-compact, hard-gate / bucket-3 / user touchpoint, or a deliberate
flush.

**Per turn** (once, at the pause that ends the turn):

6. **Push the branch**. `git push -u origin develop/<slug>`, and open the PR
   when it is ready for review. CI's `ci-required` (3-OS) is the gate.
   `main` is ruleset-protected — never push to it directly (ROADMAP §14).
7. **Final user text**: one sentence (turn's closed task id(s) + next task id).

> **CAMPAIGN-ONLY — the loop-era turn ending.** It was: one push to
> `zwasm-from-scratch`; background `run_remote_{ubuntu,windows}.sh test-all`
> kicks whose verdicts Step 0.7 read back from `/tmp/{ubuntu,win}.log`, with a
> batched Windows cadence and an ubuntu-red auto-revert; then a mandatory
> `ScheduleWakeup(delaySeconds=60, prompt="/continue")` re-arm so the loop
> continued unattended. None of it applies now — the branch is retired, CI's
> 3-OS gate replaced the SSH farm as the authority (ADR-0076 D9), the batch
> helper is deleted (ADR-0206 D5), and maintenance mode has no self-re-arm.
> [`LOOP.md`](LOOP.md) keeps the retired contract.

## Auto-compact recovery

Can't invoke `/compact` (user-only). Harness auto-fires on context
fill, silently summarising. After compact:

- System prompt + skill listing survive.
- `PostCompact` hook re-emits `print_handover_brief.sh` (open PRs /
  issues + last 3 commits). That brief = recovery anchor.
- Tool-result detail does NOT survive — only harness summary.

Two implications:

1. **Treat PostCompact brief as fresh resume.** Re-orient from the
   brief's open PRs / issues, `git log -3` + `git status`, continue
   from Step 0. **Do not stop** — auto-compact is non-stop.
2. **Commit (or push the branch) before any long subagent / background
   Bash.** Step 7 is not the only flush point; git artifacts are the
   recovery anchor, and the PR description is the cross-session note.

The loop is designed so auto-compact loses at most one task's worth
of in-flight Steps 0-3. Steps 4-6 end with git artifacts. Anchor on those.

### Repeat

Steps 0–5 (commit pair) per task, chaining in-turn where the tasks
belong to the same piece of work. At the turn's natural pause, Steps 6–7
(push, then the one-sentence status) once.

> **CAMPAIGN-ONLY.** The loop-era form of this section chained across
> `§9.<N>` rows into the phase-boundary handler and never voluntarily
> exited. Maintenance mode ends the turn when the task is done.

## Phase boundary — inline, no stop

> **CAMPAIGN-ONLY.** The phase campaign closed 2026-07-01; no `§9.<N>` row
> is open, so this handler cannot fire — do not act on it. To run an audit,
> invoke `audit_scaffolding` directly.

When the last `[ ]` in §9.<N> flips `[x]`:

1. **Mandatory: invoke `audit_scaffolding`** (Phase-boundary mandatory
   trigger). Walk §A〜G; weight §F (debt coherence) + §G (extended-
   challenge anchor commands). `block` finding: fix locally if scope
   is local, else file ADR + queue in handover. **Either path
   continues.**
2. Optional: `simplify` on phase diff. Apply behaviour-preserving;
   queue larger ones.
3. **Backfill SHA pointers for §9.<N>**: `git log --grep="§9.<N> / <N.M>" --pretty=%h | head -1` per row; one commit (`chore(p<N>): backfill §9.<N> SHA pointers`).
4. **Open §9.<N+1>**: update Phase Status widget (§9.<N> → DONE,
   §9.<N+1> → IN-PROGRESS); expand task table; refresh handover.
5. Push + re-arm (`ScheduleWakeup(60)`); resume §9.<N+1>'s Step 0.

Phase-boundary review is **opportunistic** except Step 1 (audit
mandatory).

### Exception — hard human-in-loop transition gates

A small number of phase boundaries are **hard gates** — loop MUST stop
and surface to user with the gate document. Currently registered:

- **§9.7 → §9.8**: row 7.13, doc `.dev/archive/phase_gates/phase8_transition_gate.md`
- **§9.9 → Phase 10**: row 9.13, doc `.dev/phase10_transition_gate.md`

Detection at Resume Step 2 + Step 7 re-target: row body contains 🔒 +
`.dev/phase*.md` gate reference → skip `ScheduleWakeup`, surface
one-sentence handoff. Hard gate is NOT bucket-2; it's "this needs the
user; don't proceed silently".

### Frozen invariant — the loop NEVER releases (ADR-0156)

Tagging a release, publishing binaries, or any `main` cutover is a
**manual, user-only act**. The loop has **no autonomous path to a
release** and **no release gate exists** as a loop construct — it does
NOT prepare-then-tag, surface "ready to release," or treat any phase as
a march toward a version. Phase 16 is **completion finalization (完成形)**
— surface audits (C/Zig/CLI, あるべき論 + industry-standard,
breaking-allowed; NOT v1 parity) + dogfooding + memory-safety + debt
repayment — pursued indefinitely. The loop keeps improving toward the
完成形 bar; when it is hit, the loop keeps refining / paying debt, never
"shall I release?". Version / tag / cutover come only from an explicit
user message.

## Reference tables — see `LOOP.md`

- **Chunk types** — `emit` / `architectural` / `survey` / `test-only`
  / `infrastructure` size + gate + exit rules; `architectural`
  3-cycle cap.
- **Subagent delegation cheatsheet**.
- **What NOT to invoke during the loop**.
- **Model selection (dual-model)** — Opus 4.7 for per-task TDD, Opus
  4.6 for long-context audit/simplify subagents.
- **Anti-patterns observed in past sessions** — 6 named failure modes.

All in [`LOOP.md`](LOOP.md).
