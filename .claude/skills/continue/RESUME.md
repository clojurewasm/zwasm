# Resume procedure — detailed steps

Sibling of [`SKILL.md`](SKILL.md). SKILL.md gives the outline; this
file has the detailed per-step procedure. Read on-demand when
executing a specific step.

## Step 1 — Handover + framing grep

Read `.dev/handover.md`. The `SessionStart` hook already prints it.

**Framing grep — mandatory on every resume** per
[`handover_doc_discipline.md`](../../rules/handover_doc_discipline.md)
§1:

```sh
grep -nE "user-judgment territory|wait for natural trigger|wait for .* fixtures|needs commitment to|substantial multi-cycle|deep .* work or wait|pivot to .* OR" .dev/handover.md
```

Non-empty → **the FIRST chunk this resume IS the handover.md
rewrite**. Replace forbidden framing with concrete chunk descriptions,
commit (`chore(handover): remove forbidden framing`), re-read handover,
proceed. Do not enter the prose-suggested chunk while forbidden framing
is present — the framing is unreliable by construction.

## Step 1a — Close-plan / amendment-cycle override

If handover.md's `Cold-start procedure` step 1 directs at a
`.dev/phase*_close_plan.md` OR `.dev/phase*_close_master.md` document,
that doc's `§6 Work sequence` is **authoritative for this session** —
superseding the ROADMAP-first lookup in Step 2.

The plan doc exists precisely because ROADMAP is acknowledged-stale
pending its first amendment step (step (a)). Execute the plan's step
(a) FIRST; it lands ROADMAP / ADR amendments that re-align state.
After step (a) closes, the override no longer fires (handover gets
refreshed at step (a)-6 to point at next step).

**Detection**: scan handover.md for `phase*_close_plan.md` /
`phase*_close_master.md` reference in Cold-start procedure or Active
state. Matched → plan supersedes ROADMAP for THIS session.

Distinct from hard-gates (which STOP the loop); a close-plan keeps the
loop autonomous but redirects what it works on.

## Step 1b — Bundle override (ADR-0118 D6)

If handover.md has an `## Active bundle` section with non-met
exit-condition → bundle-next-step supersedes ROADMAP §9 lookup.

**Detection**: handover contains `## Active bundle` with `Bundle-ID:` +
`Exit-condition:` AND `bash scripts/check_bundle_active.sh` exits 0
(schema valid + exit-condition not yet met).

**Action**: read the bundle's `Continuity-memo` to identify next
sub-step; enter TDD loop with that as the active task. Bundle close
(when exit-condition met) requires
`bash scripts/check_bundle_active.sh --close` to pass before retiring
the section.

Bundle delta = 0 after planned N cycles → continue (extend N in
handover) OR pivot (rewrite handover; commit chore).

## Step 2 — ROADMAP lookup

Read `.dev/ROADMAP.md`:

- Look up **Phase Status** widget at top of §9 — names IN-PROGRESS
  phase + first open `[ ]` task.
- Open that phase's §9.<N> task table; confirm first `[ ]` matches the
  widget. Disagree (drift) → widget is wrong; trust table, update
  widget.
- If §9.<N>'s task table is missing/empty → phase not opened yet;
  expand first (mirror previous phase's structure).
- **Step 1a / 1b override note**: if either fired, SKIP this check —
  the plan / bundle names work directly.

## Step 3 — git state

`git log --oneline -10` and `git status -sb`.

- Clean + origin ahead-or-equal → proceed.
- Uncommitted in-flight → decide: complete and commit, OR `git stash`
  and restart the task (cheaper than guessing).
- Local ahead of origin → push immediately (no approval; see Push
  policy in [`LOOP.md`](LOOP.md)) before Step 0.

## Step 0.4 — Lesson scan

Read `.dev/lessons/INDEX.md`. For the active task's domain
(interpreter, cross-module imports, ABI, build.zig, validator, ...),
grep the keyword column for pre-recorded learnings. Read every matching
lesson **before** Step 0 (Survey).

Cheap (≤ 30 s); prevents re-paying spike costs prior cycles paid. See
[`lessons_vs_adr.md`](../../rules/lessons_vs_adr.md) for the lesson
concept.

## Step 0.5 — Debt sweep + barrier-dissolution

`.dev/debt.yaml` is the YAML SSOT (D-227 / ADR-0129); query/edit it with
`yq` per [`yaml_ssot_yq.md`](../../rules/yaml_ssot_yq.md). For every
`now`-status entry, attempt discharge before active task. **Effort estimate
irrelevant**; only structural impossibility (`blocked-by` named barrier in
`description`) prevents discharge.

```sh
yq -r '.entries[] | select(.status == "now") | .id' .dev/debt.yaml          # discharge candidates
yq -r '.entries[] | select(.status == "blocked-by") | .id + "  " + .last_reviewed' .dev/debt.yaml  # barrier sweep
```

Discharge commit: `chore(debt): close D-NNN <one line>`. **Delete** the
entry in the same commit (`yq -i 'del(.entries[] | select(.id == env(DROW)))'`;
git log retains the trace). New debts discovered during active task get
appended at Step 7, not mid-task.

### Barrier-dissolution check (unconditional, every resume)

Regardless of `last_reviewed` date, walk every `blocked-by` entry and
re-evaluate the named barrier (the predicate at the head of `description`)
RIGHT NOW. Barrier is by construction **testable in concrete terms**:

- "§9.7 / 7.7 完了" → grep ROADMAP for the row's `[x]`
- "x86_64 regalloc port" → grep `src/engine/codegen/x86_64` for
  `regalloc` evidence
- "Zig 0.17 stdlib API" → check `zig version`

Barrier dissolved (named condition now satisfied) → **flip `status` to
`now` in the same resume** (`yq -i`), discharge alongside as if always
`now`. Check is cheap (`grep | head` per entry); runs BEFORE per-task work.
The `last_reviewed` field updated only when barrier still holds.

### Stale-barrier escalation

Scan `blocked-by` entries' `last_reviewed` dates. Entry reviewed > 3
resume cycles ago (or > 14 days) without barrier dissolution → barrier
re-walked with deeper investigation (referenced files / commands /
ADRs); `last_reviewed` → today.

**3+ entries hit this escalation in one resume** → fire `audit_scaffolding`
narrow mode (`§F` debt-coherence only) before continuing. Catches the
failure mode where multiple barriers quietly evaporated together
(closed phase, landed ADR, Zig version bump).

The discipline: **a barrier named in concrete terms always names
something testable**. Vague barriers ("later", "TBD") were forbidden
at file creation; if one slipped in, audit `§F.2` rejects the row.

## Step 0.5b — Live status check (per active phase)

When the active phase has a registered live-status script (e.g.
`scripts/p9_simd_status.sh` for §9.9; future phases drop their own per
[`handover_doc_discipline.md`](../../rules/handover_doc_discipline.md)
§2 stale-ness), run it **before** picking the next sub-chunk:

```sh
bash scripts/p<N>_*_status.sh
```

The script's output IS authoritative for "what is failing right now".
If handover.md / debt.yaml narrative disagrees with live numbers, **trust
the script + update the stale doc** before starting per-task TDD loop.
Next sub-chunk: pick from handover's `Next candidates` filtered by live
evidence.

**Why this step exists**: §9.9-g-13 surfaced a drift case (predicted
"16 cmp fails are alias case" but live = `i*x*.ne` family). Chunk's
preventive value was real; target framing was wrong. This step
prevents recurrence structurally — the rule forbids predictions; this
step verifies whatever handover *does* claim against live measurement.

When no live-status script exists (structural / refactor phases without
fail-count metric), this step is **skipped** — the next chunk that
introduces measurable failures should drop a script then, not let
handover accumulate predictions.

## Step 0.6 — Hard-gate prep awareness

When the active phase has a registered hard-gate row (see
[`SKILL.md`](SKILL.md) §"Exception — hard human-in-loop transition
gates") AND the first `[ ]` row in §9.<phase> is **at or past** the
prep-window threshold (= 3 rows before the hard-gate row; e.g. §9.7
with hard gate at 7.13 → 7.10 onward), open the hard-gate document
(`.dev/phase<N+1>_transition_gate.md`) and:

- Cross-check every checkbox under "design cleanliness extrapolation"
  / "deferred-work dependency DAG" sections against current code state.
- For any unmet checkbox mapping to concrete code change, ensure a
  corresponding `.dev/debt.yaml` row exists (Status: `now` if all
  predecessors landed, else `blocked-by: <named predecessor>`).
- Gate-checkbox unmet item with NO corresponding debt row AND no
  ROADMAP §9.<phase> row → file the debt entry **immediately**.

Cheap (one file read + grep); runs BEFORE per-task TDD picks the next
chunk. Ensures hard-gate prep work is discoverable as `now` debt while
there's still iteration budget — NOT deferred to gate review where it
surfaces as "unchecked checkboxes with no work-tracking artifact".

## Step 0.7 — Prior cycle ubuntu verification (ADR-0076 D3)

Previous cycle pushed source+handover in one commit pair and kicked
`run_remote_ubuntu.sh` in background (ADR-0076 D2/D3). Result verified
HERE, mechanically.

```sh
tail -3 /tmp/ubuntu.log
```

OR `Read /tmp/ubuntu.log` (small offset from end). Equivalent.

**Expected**: line `[run_remote_ubuntu] OK (HEAD=<sha>)` whose `<sha>`
matches `git log -1 --format=%h origin/zwasm-from-scratch~0`. Matched
→ proceed to Step 6.

**FAIL OR stale log** (HEAD mismatch / log missing / abort marker):
**revert prior commit pair**:

```sh
git reset --mixed HEAD~2   # source + handover commits
```

Diff stays in worktree. Investigate failure (Read log tail; `grep -i
'FAIL\|error' /tmp/ubuntu.log`), fix in place, re-run Step 5, resume
Step 6. Commit pair re-built atop fix; one push lands corrected chunk
+ fix as one cycle.

### First-resume exception

`/tmp/ubuntu.log` doesn't exist (first cycle after rule landed, OR log
was cleared) → skip silently.

### Non-code-gap exception

Log SHA older than origin HEAD but diff between them touches NO code
gate inputs (= no `src/`, `test/`, `include/`, `build.zig`,
`build.zig.zon`, `flake.nix`, `flake.lock`) → gap is skill / docs /
hook / `bench(ci)` commits that never needed ubuntu. Skip silently.

```sh
log_sha=$(awk -F'[=)]' '/OK \(HEAD=/{print $2}' /tmp/ubuntu.log | tail -1)
git diff --name-only "${log_sha}..origin/zwasm-from-scratch" -- \
    src/ test/ include/ build.zig build.zig.zon flake.nix flake.lock
```

Empty → non-code-gap, proceed. Non-empty → genuine code pushed
unverified → revert per FAIL path.

This exception exists because skill-edit / hook update / `bench(ci):
record <sha>` bot / CLAUDE.md tweaks land on origin between code
cycles. Previous strict shape mis-fired on these by destroying valid
docs commits.

### Force-push forbidden by §14

Failing commit pair WAS already on origin. After local revert + fix,
next cycle's single push lands as follow-up — broken state visible in
`git log` but not in working state. Acceptable because
`zwasm-from-scratch` is the development branch; `scripts/gate_merge.sh`
re-runs strict 3-host `test-all` before any `main` push.

This step joins the mechanical-checkpoint family alongside Step 3
(`git log`), Step 0.5 (debt sweep), Step 0.5b (live status). It is a
runnable command in the loop's procedure, NOT a "remember to check"
rule.
