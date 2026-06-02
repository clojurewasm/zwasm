# Phase 10 Preparation — decision-gathering phase

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

> **Mode**: surveys + draft documents only. **No `src/` changes.**
> The autonomous `/continue` loop runs each track to a deliverable,
> then **stops** (no `ScheduleWakeup` re-arm) so the user can review
> and decide. Modeled after the §9.7 → §9.8 hard-gate pattern.
>
> **Status: ACTIVE (started by §9.9-h-14 close, 2026-05-11).**

## Why this phase exists

§9.9 close + Phase 10 entry have 4 design decisions the autonomous
loop cannot make alone (each requires human judgment between named
alternatives). Surfacing them all at once at Phase 9 boundary would
overload the gate review. This prep phase produces evidence + draft
documents for each, **one track at a time**, so review chunks are
right-sized.

## Loop contract (per-track)

For each track A..D in order:

1. **Read** the track's scope below.
2. **Survey + draft** the deliverable. Code-touch is forbidden;
   the deliverable is always a Markdown file (survey note OR draft
   ADR OR draft gate doc).
3. **Commit** the deliverable as
   `docs(p10-prep): track <X> — <one line>`.
4. **Surface to user** with one sentence: `Phase 10 prep Track <X>
   complete; deliverable at <path>; awaiting decision before
   proceeding.`
5. **Do NOT re-arm** `ScheduleWakeup`. Treat resumption as bucket-1
   user intervention (the user reviews, decides, may amend the
   deliverable in place or hand back, then types `/continue` to
   start the next track OR to begin implementing the decision).

The loop's per-task TDD steps map as: Step 0 (survey) = the bulk
of the deliverable; Steps 2–5 (red/green/refactor/test gate) are
skipped (no code); Step 6 (commit) lands the doc; Step 7 (handover
update + push + re-arm) is **modified** — re-arm is suppressed per
above.

## Tracks (run in order A → B → C → D)

### Track A — §9.10 scope reality check

**Question.** Does §9.10 ("SIMD smoke benches + per-op gap profile
against wasmtime / wazero / wasmer") stay as written, get descoped
to a baseline-only step, or move entirely to Phase 11?

**Why it matters.** §9.10's prerequisite is `bench/results/
history.yaml` + 3-runtime comparison infrastructure. D-074
documents that ADR-0012 §1–§3 (tier-provisioning + `bench/{wat,
custom, embenchen}/` + `versions.lock` + `setup_corpora.sh` +
`-Dwith-bench-compare` flag) is **unimplemented** and its barrier
says `no Phase row currently scheduled; likely Phase 11`. If
§9.10 expects bench infra, it can't close without D-074.

**Survey scope.**

- Read `.dev/decisions/0012_first_principles_test_bench_redesign.md`
  §1–§3 + Amendment log.
- Read `.dev/decisions/0043_*.md` for the "per-op gap analysis"
  + "3× threshold" + v1 D122 reference (D-076 verify task).
- Read `.dev/debt.yaml` D-074 row.
- Inventory current `bench/` directory layout (`ls bench/`,
  `ls scripts/run_bench.sh` etc.) and assess gaps.
- Check if wasmtime / wazero / wasmer are in `flake.nix` dev shell
  OR installable.

**Deliverable.** `private/notes/p10-prep-track-a-9.10-scope.md`
listing **2–3 scope options**:

- Option (1) full per-op gap profile as currently written
  (requires D-074 substantial implementation).
- Option (2) baseline-only — wire `bench/run.sh` against just
  wasmtime, record `history.yaml` per-bench, defer per-op gap
  analysis to Phase 15 alongside the SIMD-specific optimisation
  cycle.
- Option (3) move entire §9.10 to Phase 11 alongside D-074 (whole
  bench infra cohort).

For each option: required prerequisites, estimated chunk count,
what it commits to / forecloses. End with a one-paragraph
**recommendation** + brief rationale.

**Stop after.** Surface to user; await Option (1/2/3) decision.

### Track B — D-057 / D-065 source-split file partition

**Question.** What's the concrete file partition for `op_simd.zig`
(4554 LOC) + `inst_neon.zig` (2249 LOC) + `op_simd_test.zig`
(2624 LOC) — all breaching §A2's 2000-LOC hard cap?

**Why it matters.** Phase 10 will add more SIMD-adjacent handlers
(GC + memory64 share infrastructure with SIMD's spill/Q-form
ABI). Without the split, Phase 10 chunks will repeatedly trip
file-size warnings and accumulate LOC ratchet. ADR-0053's
"co-deliverable" clause promised this but didn't land.

**Survey scope.**

- Enumerate handlers in `op_simd.zig` by op family: int binop /
  int unop / int cmp / int shift / FP binop / FP unop / FP cmp /
  lane (extract/replace/splat) / memory (load/store/load_splat/
  load_lane/load_extend/load_zero) / shuffle/swizzle / pack /
  bitwise / convert.
- Repeat for `inst_neon.zig` encoders.
- Repeat for `op_simd_test.zig` test groups.
- Read `.dev/decisions/0030_*.md` for the precedent emit.zig split
  pattern (D-051 close).
- Read ARM64 `op_simd.zig` for parity considerations.

**Deliverable.** `private/notes/p10-prep-track-b-source-split.md`
containing:

- **A partition table** per file, columns: `current file → new file
  | op group / handler list | LOC estimate`.
- An **ADR draft skeleton** (ADR-0054, Title "Source-split
  op_simd.zig + inst_neon.zig per §A2 cap") with Context /
  Decision / Alternatives / Consequences sections roughed in —
  the user finalises the decision.
- **Migration plan** in chunks (e.g. "9.9-h-15 split op_simd_int.
  zig", "9.9-h-16 split op_simd_fp.zig", …). Estimate ≤ 6
  chunks total.

**Stop after.** Surface to user; await partition approval (the
user may amend the table inline before the ADR lands).

### Track C — ADR-0029 path A vs B (skip semantics for §9.9 close)

**Question.** Does `skip = 0` in §9.9's exit criterion mean
literally zero SKIPs, or zero `skip-impl` with `skip-adr` waived
by design?

**Why it matters.** Current SKIP backlog (Mac + OrbStack each
2357):

| Category                          | Count | Driver                                   |
|----------------------------------|------|------------------------------------------|
| nan-or-bad-token                  | 1222 | NaN-aware compare not implemented        |
| v128-param-pending                |  788 | More entry helpers needed (mechanical)   |
| directive-assert_malformed-text   |  390 | Text-format parser absent (by-design per ADR-0029) |
| assert_trap-v128-pending          |   18 | v128-result assert_trap runner gap       |
| export-name-has-spaces            |    3 | Niche tokenizer quirk                    |

D-072 + D-073 already track the "ADR-0029 design ↔ implementation
divergence". This Track decides the resolution.

**Survey scope.**

- Read `.dev/decisions/0029_spec_test_skip_semantics.md` fully.
- Read D-072 + D-073 + D-076 in `.dev/debt.yaml`.
- Read `test/spec/spec_assert_runner.zig:48-108` (current
  classification + reason-string mapping).
- Read `scripts/regen_spec_simd_assert.sh:226-280` (how `skip`
  directives are emitted).
- Run `grep -rn "skip-impl\|skip-adr" test/spec/` to inventory
  current usage (D-073 noted: 0 matches).

**Deliverable.** `private/notes/p10-prep-track-c-adr-0029-path.md`
listing:

- **Path A** — amend ADR-0029 in place to match runner-internal
  reality (`skip` raw → runner classifies via reason mapping).
- **Path B** — migrate manifests to `skip-impl <field>` /
  `skip-adr-<ADR-id> <field>` prefix vocabulary; ADR-0029 design
  becomes load-bearing; D-072 + D-073 discharge via the
  migration.
- Per-path: implementation cost, what closes (D-072 / D-073 /
  D-076 / §9.9 skip exit), what new debt opens.
- **Recommendation** + draft ADR-0029 amendment OR new ADR-0055
  (the user picks at review time).

**Stop after.** Surface to user; await Path (A/B) decision +
ADR amendment finalisation.

### Track D — Phase 10 transition gate doc

**Question.** What goes in `.dev/phase10_transition_gate.md`
(the collaborative review checklist analogous to
`.dev/archive/phase_gates/phase8_transition_gate.md`)?

**Why it matters.** `/continue` skill's hard-gate detector
requires a row to contain `🔒` AND a `phase<N>_transition_gate.md`
reference. Phase 10's row in §9 has `🔒` but no transition gate
doc exists — the autonomous loop will sail past it unprepared.

Phase 10 = Wasm 3.0 completion (GC + EH + tail call + memory64).
Each is a substantial subsystem with its own design surface;
without per-subsystem ADRs first, the loop will either churn on
writing them OR start implementation without architecture.

**Survey scope.**

- Read `.dev/archive/phase_gates/phase8_transition_gate.md` end-to-end for shape /
  section structure / "design cleanliness extrapolation" + "deferred
  -work dependency DAG" formats.
- Enumerate Phase 10's 4 subsystems' current state in the codebase
  (search `ref.test`, `try_table`, `return_call`, `memory64`
  occurrences — likely all absent).
- Inventory existing ADRs that touch Phase 10 territory
  (`grep -l "Phase 10\|GC\|exception\|tail call\|memory64"
  .dev/decisions/`).
- List Phase 10 prep work items already filed (D-079 (ii) v128
  cross-module imports, D-074 bench infra, etc.).

**Deliverable.** `.dev/phase10_transition_gate.md` **as a draft**
containing at minimum:

- §1 — Goal + scope (Wasm 3.0 boundary).
- §2 — Per-subsystem entry checklist (4 subsystems, each: design
  ADR landed? validator extension scoped? IR ZirOp catalogue
  decided? per-arch emit strategy sketched?).
- §3 — Design cleanliness extrapolation (mirror phase8's
  §3 shape).
- §3a — Deferred-work dependency DAG (D-079 (ii), D-074, D-057 /
  D-065 source-split must close FIRST, etc.).
- §4 — Open questions for user.
- §5 — Resume protocol (when each checkbox flips ☑, gate
  approaches closure; the §9.<phase> 7.13-equivalent row's
  flip-to-`[x]` is the formal close trigger).

Also update §9.12 row in `.dev/ROADMAP.md` (or add a §9.13)
to reference `.dev/phase10_transition_gate.md` so the
`/continue` hard-gate detector fires.

**Stop after.** Surface to user; await checklist amendment +
ROADMAP row update approval.

## After all 4 tracks complete

User holds 4 decisions:

- §9.10: keep / descope / move to Phase 11.
- D-057: ADR-0054 partition approved → triggers chunks
  9.9-h-15..-N.
- ADR-0029: path A or B → triggers either ADR amendment
  (path A) or manifest migration chunks (path B).
- Phase 10 gate: checklist + ROADMAP wiring in place → autonomous
  loop now correctly halts at the gate; per-subsystem prep
  (parallel to Phase 9's ADR-0041 framing) becomes the next prep
  phase.

At that point, normal autonomous `/continue` resumes (no more
prep mode). The handover `Active state` flips back to "in
chunk", and the §9.9 close / §9.10 / §9.11 / §9.12 rows progress
normally driven by the resolved decisions.

## Anti-patterns (do not repeat)

- **Don't pick a track out of order** — A → B → C → D is the
  dependency order. Track A's outcome may change §9.10 row
  wording; Track C may change skip counting which affects
  Track A's "does §9.10 even close in §9 scope" question.
- **Don't write code** — every deliverable is a Markdown file.
  If a track surfaces a question that REQUIRES code investigation
  (e.g. "what does `bench/run.sh` actually do?"), bounded code
  reads via Read tool are OK; code edits are not.
- **Don't combine tracks** — each track's deliverable lands as
  its own commit. User reviews one at a time.
- **Don't re-arm `ScheduleWakeup`** — every track ends with
  surface-to-user. The user explicitly resumes by typing
  `/continue` when ready for the next track.
