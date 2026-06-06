---
name: continue
description: Resume fully autonomous work on zwasm-from-scratch and drive the per-task TDD loop until the user intervenes or a problem is identified that genuinely cannot be solved. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Reads handover, finds next task, runs tests, then immediately enters the TDD loop with no "go" gate, no Phase-boundary stop, and no per-task confirmation. Auto-runs adaptive audit_scaffolding inline, continues into the next Phase without prompting, pushes its own commits to origin/zwasm-from-scratch, and re-arms itself via ScheduleWakeup so overnight / no-reply sessions keep iterating.
---

# continue

Pick up where the previous session left off and **drive the iteration
loop fully autonomously, indefinitely, without user babysitting**. The
user invoked `/continue` precisely to walk away and expect a long chain
of green commits, not a "shall I proceed?" prompt.

This skill is **opinionated about context discipline and
self-perpetuation**: delegate heavy reads to subagents, compact
proactively, reset at phase boundaries, push, and re-arm so the loop
survives even when the user is not present.

## Stop conditions — strict 3-bucket whitelist

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

Push policy + Self-perpetuation (the `ScheduleWakeup` re-arm contract):
sibling file [`LOOP.md`](LOOP.md). Read once per session at the top of
resume; does not change between iterations.

## Bundle mode (ADR-0118 D6)

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
delta verified — `bash scripts/check_bundle_active.sh --close` enforces
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
quality do (design priority: memory
`feedback_design_priority_completeness_over_v010`). The rework stays
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

Detection: handover `## Active rework campaign` (Resume Step 1c).
Bundle mode is used WITHIN a campaign phase for continuity.

## Resume procedure (run on every session pickup)

Outline (full details in [`RESUME.md`](RESUME.md)):

1. **Read handover.md + framing grep** — per
   `handover_doc_discipline.md` §1. If forbidden phrases found
   (`user-judgment territory` etc.), the FIRST chunk this resume IS
   the handover rewrite.
1a. **Close-plan / amendment override** — handover points at
    `phase*_close_plan.md` / `phase*_close_master.md` → plan's §6 Work
    sequence supersedes ROADMAP for this session.
1b. **Bundle override (NEW)** — handover has `## Active bundle` with
    non-met exit-condition → bundle-next-step supersedes ROADMAP.
    (If a `## Active rework campaign` is ALSO present, 1c is the outer
    frame and is checked first — this bundle is its current-phase
    continuity.)
1c. **Campaign override (ADR-0153)** — **checked before 1b.** handover
    has `## Active rework campaign` → it is the outer frame; its
    current-phase next-step supersedes ROADMAP. Read [`REWORK.md`](REWORK.md);
    honour the phase order (I+II are hard gates before any redesign
    code). A nested `## Active bundle` is read as the current phase's
    per-multi-cycle continuity (1b mechanics apply WITHIN the phase).
2. **Read ROADMAP** — Phase Status widget + first `[ ]` row. Skip
    when Step 1a / 1b / 1c fired.
3. **git log + status** — clean: proceed. Uncommitted in-flight:
   complete or stash. Local ahead of origin: push immediately.
4. **Step 0.4 — Lesson scan** ([`RESUME.md`](RESUME.md#step-04)).
5. **Step 0.5 — Debt sweep + barrier-dissolution check**
   ([`RESUME.md`](RESUME.md#step-05)).
5b. **Step 0.5b — Live status check** (per-phase `p<N>_*_status.sh`
   if exists) ([`RESUME.md`](RESUME.md#step-05b)).
5c. **Step 0.6 — Hard-gate prep awareness** (within 3 rows of a
   registered hard gate) ([`RESUME.md`](RESUME.md#step-06)).
5d. **Step 0.7 — Prior-cycle remote verification (ADR-0076 D3+D7)** —
   `tail -3 /tmp/ubuntu.log` AND `tail -3 /tmp/win.log` mechanically.
   **ubuntu** FAIL → revert prior commit pair (D3; first-resume + non-code-gap
   exceptions apply). **windows** FAIL (D7) → do NOT auto-revert: re-run the
   failing exe once → reproduces = real Win64 bug (debt row + fix); flake =
   `bash scripts/track_heisenbug.sh <name> segv` + proceed.
   ([`RESUME.md`](RESUME.md#step-07)).
6. `zig build test` (Phase 0+); `test-spec` from Phase 1; differential
   from Phase 7. Output >200 lines → subagent.
7. **One-sentence status** (phase + last commit + next task). No
   multi-line summary.
8. **Immediately enter TDD loop.** `/continue` itself is the go signal.

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

Re-open ROADMAP §9.<N> task table; confirm first `[ ]` matches
handover. Disagreement → trust ROADMAP, update handover.

**Close-plan override** (Step 1a fired): plan doc is authoritative;
"trust ROADMAP over handover" is inverted during step (a) amendment
cycle.

**Bundle override** (Step 1b fired): handover's `## Active bundle`
names next step; do not look up ROADMAP §9.<N>.

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

### Step 6+7 — Commit pair (per chunk) + push/kick/re-arm (per turn) (ADR-0076 D2+D5)

A turn chains **N chunks**; sub-steps 1–5 run per chunk, 6–8 once at
turn end (ADR-0076 D5-a/b). The legacy 2-push cycle is a single-push
commit pair per chunk.

**Per chunk** (every chunk in the turn):

1. **Source commit**. `git add <files>; git commit -m "<type>(<scope>): <line>"`.
   Pre-commit gate (`gate_commit.sh --fast`) runs — that IS the
   commit check; do NOT additionally run `zig build test` / `lint` /
   `file_size_check` standalone (D5-c; Step 5 already ran test once).
   Never `--no-verify` (§14 forbidden).
2. **Update handover.md** (replace, not append): Current state (5
   lines, Phase + last SHA + next task), Active task (chunk progress
   with **NEXT** marker). Length is **soft 100 / hard 120**
   (`handover_doc_discipline.md` §6) — relax in the 100–120 band, do
   NOT micro-trim to exactly 100; relocate stable content to
   `CLAUDE.md` / skill / rule only when it exceeds 120.
3. **Mark `[x]` for completed task in ROADMAP §9.<N>**. SHA stays
   bare; batch-backfilled at phase close. **§18 self-check** (PreToolUse
   hook re-prints): routine `[x]` flip + SHA backfill = no ADR.
   Touching §1/§2/§4/§5/§9 scope/§11/§14 = deviation; file ADR first.
4. **Append `.dev/debt.yaml` + lessons** as needed.
5. **Handover commit**. `git commit -m "chore(p<N>): mark §9.<N> / N.M [x]; retarget handover at N.M+1"`.

→ **Then CHAIN (D5-a; D8 reinforces — chain BIG)**: go straight to the
next chunk's Step 0 in the **same turn**, keeping working context. Do NOT
push/kick/re-arm between chunks. **Default to MANY chunks per turn (larger
granularity)** — Mac+ubuntu are the fast loop; pack several debt-items /
slices into one turn before flushing. End the turn only at a natural
pause: immediately-actionable work exhausted, approaching context-fill /
auto-compact, hard-gate / bucket-3 / user touchpoint, or a deliberate
flush. **Do NOT end a turn just to poll the windows gate** (D8) — it runs
batched in the background; verify its verdict at the next Step 0.7.

**Per turn** (once, at the pause that ends the turn):

6. **Single push (ADR-0076 D2)**. `git pull --rebase --autostash origin zwasm-from-scratch && git push origin zwasm-from-scratch`.
   One push lands ALL the turn's commit pairs (rebase integrates the
   bench-CI bot commits once).
7. **Remote kicks (background; ADR-0076 D3+D5-b+D6+D8)**. `run_in_background: true`,
   do NOT wait. **ubuntu = always** (D6): `bash scripts/run_remote_ubuntu.sh test-all
   > /tmp/ubuntu.log 2>&1` (x86_64, every turn). **windows = BATCHED** (D8 — windows
   is the slow host; batch it, NEVER poll-wait on it): run
   `bash scripts/should_gate_windows.sh`; **exit 0 →**
   `bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1` (Win64), then
   after the next-cycle green verify `scripts/should_gate_windows.sh --record`. The
   batched cadence (≥6 commits if the batch touched ABI/calling-convention/frame-layout
   paths, else ≥12; ABI-risk no longer immediate) keeps iteration fast on Mac+ubuntu
   while still catching Win64 drift per batch. **Do NOT end a turn or re-arm merely to
   poll windows** — kick it in the background when the batch fires, keep chaining the
   next chunks, and verify its verdict at the next Step 0.7 whenever it lands. ubuntu
   red → auto-revert (D3). **windows red → NOT auto-revert** (heisenbug-prone): re-run
   once → reproduces = real bug (debt+fix); flake = `track_heisenbug.sh` + proceed.
8. **Re-arm**: `ScheduleWakeup(delaySeconds=60, prompt="/continue")`.
   Literal `60` = harness floor (`[60, 3600]` clamp). The tool
   description's "default 1200–1800s" does NOT apply — see
   [`LOOP.md`](LOOP.md) §"Self-perpetuation". Mandatory.
9. **Final user text**: one sentence (turn's closed task id(s) + next task id).

## Auto-compact recovery

Can't invoke `/compact` (user-only). Harness auto-fires on context
fill, silently summarising. After compact:

- System prompt + skill listing survive.
- `PostCompact` hook re-emits `print_handover_brief.sh` (handover.md +
  last 3 commits). That brief = recovery anchor.
- Tool-result detail does NOT survive — only harness summary.

Two implications:

1. **Treat PostCompact brief as fresh resume.** Re-read handover.md,
   locate active task, `git log -3` + `git status`, continue from
   Step 0. **Do not stop** — auto-compact is non-stop.
2. **Update handover.md before any long subagent / background Bash.**
   Step 7 is not the only flush point. The cost is a 30s edit; value
   is not losing bearings overnight.

The loop is designed so auto-compact loses at most one task's worth
of in-flight Steps 0-3. Steps 4-6 end with git artifacts; Step 7 ends
with handover + wakeup. Anchor on those.

### Repeat

Steps 0–5 (commit pair) for each `[ ]` task in §9.<N>, **chaining
in-turn** (D5-a) — back-to-back without push/re-arm. At the turn's
natural pause, Steps 6–8 (push/kick/re-arm) once. Then Phase
boundary. Then §9.<N+1>'s Step 0. Loop never voluntarily exits.

## Phase boundary — inline, no stop

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
