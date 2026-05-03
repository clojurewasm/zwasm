# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md` —
   redesign + refactoring sweep that lands inside Phase 6 before
   close. Defines work-item block §9.6 / 6.K (Value funcref,
   ownership model, cross-module imports, element forms 5/7,
   Label arity formalisation, partial-init re-measure).
3. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred
   items; 6.K is appended per ADR-0014 §18 amendment).

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D + 6.K.1 + 6.K.2 done;
  ADR-0015 done; ADR-0016 drafting next; then 6.K.3〜6.K.7 + 6.E +
  6.F〜6.J).
- **Last source commit**: `4d849ae` — docs(p6) land ADR-0015 +
  ROADMAP §9.6 / 6.K.7. Self-review found 5 block + 7 nit; all
  applied. Mac + OrbStack unit green; full three-host gate
  deferred to next implementation cycle (text-only commit).
- **Pre-amble for the next cycle**: ADR-0016 is a non-TDD cycle.
  Follow `## Autonomous loop override` below until ADR-0016 is
  accepted, **then delete that block** (Step H of the ADR-0016
  cycle removes the override; thereafter the standard /continue
  TDD loop resumes for §9.6 / 6.K.3).
- **Branch**: `zwasm-from-scratch`, pushed.

## Autonomous loop override — ADR drafting cycles (ADR-0015 then 0016)

> **DELETE this entire section** at the end of the ADR-0016 cycle's
> Step 7 (after ADR-0016 lands and ROADMAP §9.6 / 6.K.8 is marked
> [x]). The standard `/continue` TDD loop resumes for §9.6 / 6.K.3
> from the next wakeup. Until then, every wakeup follows this
> override instead of the skill's default Step 0–7.

### When to apply

Apply this override iff `Active task` (below) names an ADR draft.
Skip and use the standard TDD loop iff `Active task` names a
ROADMAP §9.6 row.

### ADR drafting cycle — Step A through Step H

#### Step A — Read the input survey

Inputs (gitignored, already produced by background research agents):

- ADR-0015: `private/notes/debug-toolkit-survey.md` (588 lines)
- ADR-0016: `private/notes/error-system-survey.md` (873 lines)

#### Step B — Draft the ADR

Land at `.dev/decisions/<NNNN>_<slug>.md`. Follow
`.dev/decisions/0000_template.md` — Status / Date / Author / Tags
front-matter, then Context / Decision / Alternatives / Consequences
/ References. Imperative-mood title.

ADR shape constraints:

- ADR-0015 must **retroactively cover commit `6b8981d`** (already
  landed: dbg.zig + flake additions + private/dbg/_template/) and
  scope the **remaining** work as new ROADMAP rows.
- ADR-0016 phase-1 scope is **CLI parity recovery + Diagnostic
  type definition only**. Full 5-phase migration is queued in the
  ADR's "Migration path" section but **only phase 1 lands inside
  Phase 6**. Phases 2–5 land alongside §9.6 close or pre-v0.1.0.
- Both ADRs amend ROADMAP §9.6 to add a new row (6.K.7 for
  ADR-0015's residual work; 6.K.8 for ADR-0016 phase-1
  implementation). The ADR itself is the §18 cover for the
  amendment — this is the chicken-and-egg resolution.

#### Step C — Self-review (background subagent, blind context)

Dispatch via `Agent` tool, `subagent_type=general-purpose`,
`run_in_background=true`. Brief shape:

> Critique the attached ADR draft (`.dev/decisions/<NNNN>_<slug>.md`)
> from a blind reviewer's perspective. Inputs: the draft itself,
> the source survey at `private/notes/<file>.md`, and the
> ROADMAP/CLAUDE.md context the project is built on. Flag:
> (1) decisions that aren't actually justified by the survey,
> (2) Alternatives section gaps (decisions presented as obvious
>     when there are real competing options),
> (3) Consequences gaps (cost / migration risk under-stated),
> (4) ROADMAP §2 P/A or §14 forbidden-list violations,
> (5) front-matter / structure deviations from
>     `.dev/decisions/0000_template.md`,
> (6) "carry-over from v1 with minor renames" smell — cite which
>     v1 file the draft seems to mirror, if any.
> Return ranked findings (block / nit / suggestion). Under 400 lines.

While the agent runs, work on *implementation* (Step E) only if it
can be undone cheaply; otherwise wait. Don't proceed to Step F
until Step C completes.

#### Step D — Apply review feedback

For each `block` finding: address before commit. For `nit`: address
unless cosmetic. For `suggestion`: judge — apply if cheap, defer to
a follow-up ADR if not. Re-run Step C only if a finding required
substantial rewrite.

#### Step E — Implementation (only if ADR mandates code now)

For ADR-0015: extend commit `6b8981d` with whatever the ADR
mandates (e.g., `-Dsanitize=address` build option,
`zig build run-repro -Dtask=...` step, ROADMAP §9.6 / 6.K.7 row
added inline). Use TDD shape: red test → minimal green → refactor
→ Mac lint → three-host gate.

For ADR-0016 phase 1: implement the Diagnostic type +
`setDiag(...)` + `formatDiagnostic(...)` + CLI render parity at
`src/cli/main.zig:58`. Use TDD shape; the red test is the v1
parity check (e.g., a known-failing wasm should print
"trap: out-of-bounds memory access" not "ModuleAllocFailed").

#### Step F — Self-review the implementation diff

If Step E ran, dispatch `pr-review-toolkit:code-reviewer`
subagent (`run_in_background=true`) with the diff and the ADR
text. Brief: review for adherence to the ADR's Decision section,
Zone discipline, ADR-0014 invariants, ROADMAP §14 forbidden list,
v1 copy-paste smell. Apply feedback the same way as Step D.

#### Step G — Commit + push

Commit the ADR + any implementation in one commit (or two if
chunkier — ADR commit then implementation commit, but both pushed
together). Reference the ADR in the commit message.

#### Step H — Handover update + re-arm

1. Mark the just-finished ADR's row done in the table below
   (`[x] <sha>`).
2. If the next row is the other ADR: keep this section, update
   `Active task` below.
3. If both ADRs are done: **delete this entire `## Autonomous loop
   override` section AND the `## Active task — ADR cycle` section
   below**, replacing them with a fresh standard `## Active task`
   section pointing at §9.6 / 6.K.3. The next wakeup will run the
   standard TDD loop.
4. `git push origin zwasm-from-scratch`.
5. `ScheduleWakeup` re-arm (60–270s if cache warm, 1200s if a
   long subagent is in flight).

### Stop conditions specific to ADR cycles

In addition to the skill's bucket-1 (user intervention) and
bucket-2 (genuinely unsolvable):

- **Stop if Step C self-review returns a `block` finding that
  conflicts with ROADMAP §2 (P/A) or §14**. File the conflict in
  `Open questions / blockers` below. Do not autonomously override
  the ADR's design vs ROADMAP — that's user-judgment territory.
- **Stop if Step F self-review returns a `block` that needs an
  ADR-grade redesign**. Same handling.

## Active task — ADR-0016 (error diagnostic system, phase 1)

Cycle order:

| #         | What                                                                                  | Status         |
|-----------|---------------------------------------------------------------------------------------|----------------|
| ADR-0015  | Canonical debug toolkit                                                               | [x] 4d849ae    |
| ADR-0016  | Error diagnostic system (Diagnostic type + CLI parity, phase 1 only)                  | [ ] **NEXT**   |

Once ADR-0016 [x], delete this section + the override above and
resume standard TDD on §9.6 / 6.K.3 (the next [ ] row in
`.dev/ROADMAP.md` §9.6 task table).

### ROADMAP §9.6 — task table snapshot (for reference; authoritative table is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [x] e6e5c20    |
| 6.K.3 | Cross-module imports for table / global / func (after 6.K.1 + 6.K.2)                 | [ ] (queued)   |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ]            |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |
| 6.K.7 | -Dsanitize=address + zig build run-repro (per ADR-0015)                              | [ ]            |
| 6.K.8 | (to be added by ADR-0016 — Diagnostic type + CLI parity phase 1)                     | [ ] (pending ADR-0016) |

After 6.K all-`[x]`, 6.E re-measures (29 fails flow through),
then 6.F / 6.G / 6.H, 6.I parallel, then 6.J strict close.

## Phase 6 close → Phase 7 (JIT v1 ARM64) — direct transition

ADR-0014 cancels the placeholder "post-Phase-6 refactor phase"
wiring. Phase 7 is unchanged (JIT v1 ARM64 baseline), no
renumber, no follow-up ADR. The `continue` skill's standard
§9.<N> → §9.<N+1> phase boundary handler applies as-is once
6.K + 6.E + 6.F / 6.G / 6.H / 6.I + 6.J all `[x]`.

## Phase 6 reopen DAG (ADR-0012 §6 + ADR-0014 §2.1)

```
6.A ✅  6.B ✅  6.C ✅  6.D ✅
 │
 ├─→ 6.E ⏳ (28 fails; resolves through 6.K)
 │    │
 │    ├─→ 6.K.1 ─→ 6.K.2 ─→ 6.K.3 ─→ 6.K.6
 │    ├─→ 6.K.4   (parallel)
 │    └─→ 6.K.5   (parallel)
 │           │
 │           └─→ {6.F, 6.G, 6.H} → 6.J → §9.7 (JIT v1 ARM64)
 │
 └─→ 6.I (parallel)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over;
  loop-with-params closes alongside 6.K.5 once a multi-param
  fixture lands
- element-section forms 2 / 5 / 6 / 7 — closes at 6.K.4
- ref.func declaration-scope — Phase 2 chunk 5e (independent of
  6.K)
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps)
- 39 trap-mid-execution realworld fixtures — covered through
  6.E + 6.K.3 cross-module wiring
- 10 SKIP-VALIDATOR realworld fixtures
- 28 wasmtime_misc runtime-runner failures (resolved through
  6.K per ADR-0014 §2.1)

## Open questions / blockers

(none — autonomous loop continues 6.K.1 → 6.K.6 → 6.E re-run →
6.F / 6.G / 6.H / 6.I → 6.J. No follow-up ADR after 6.J close.)
