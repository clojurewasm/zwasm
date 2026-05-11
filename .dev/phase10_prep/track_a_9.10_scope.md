# Phase 10 prep — Track A: §9.10 scope reality check

> Status: **DRAFT — awaiting user decision**
> Date: 2026-05-11
> Author: autonomous `/continue` loop, Phase 10 prep mode
> Path note: `phase10_prep.md` Track A names
> `private/notes/p10-prep-track-a-9.10-scope.md`. `private/` is
> gitignored (`.gitignore:23`), so the deliverable cannot be
> committed there. Relocated to `.dev/phase10_prep/` (sibling of
> `.dev/phase10_prep.md` and `.dev/phase10_transition_gate.md`).

## §1. Question

§9.10's current ROADMAP row text reads (line 1649):

> SIMD smoke benches against wasmtime + wazero + wasmer; recorded
> to `bench/results/history.yaml` per ADR-0012. **Per-op gap
> analysis required**: identify ops where v2 lags by > 3× the
> median of (wasmtime, wazero, wasmer) and file Phase 15 debt
> entries naming the candidate optimisation (AVX path adoption
> gated on CPUID, MOVAPS preamble peephole at op_simd binop
> sites, SIMD-specific coalescing). v1 reached "adequate for
> embedded" but explicitly accepted ~43× gap to wasmtime (D122);
> v2 inherits this gap as starting point and §9.10 produces the
> gap profile that drives Phase 15 SIMD-specific work scope
> beyond v1 W43/W44/W45 porting.

Does this stay as written, get descoped to a baseline-only step,
or move entirely to Phase 11?

## §2. Evidence — current bench infra state

### §2.1 What exists today

- `bench/README.md` (committed) — documents the
  `results/{recent,history}.yaml` split per ADR-0012 §7.
- `bench/results/history.yaml` (committed; phase-boundary
  append-only) and `bench/results/recent.yaml` (gitignored;
  rolling per-commit).
- `bench/runners/wasm/{handwritten,shootout,tinygo}/` + a
  `PROVENANCE.txt` — the actual fixture inventory used by
  `scripts/run_bench.sh`.
- `bench/sightglass/` — vendored upstream Bytecode Alliance
  sightglass suite (per 6.I).
- `scripts/run_bench.sh` — hyperfine wrapper that runs
  `zwasm run <wasm>` for each fixture; writes `recent.yaml`;
  with `--phase-record`, ALSO writes one row to `history.yaml`.
- `.github/workflows/bench.yml` — per-push CI runs
  `--quick --phase-record` on macOS-latest + ubuntu-latest;
  aggregates results into one `bench(ci): record <sha>` bot
  commit (e.g. `e59d62cd` from this branch's log).
- `scripts/record_merge_bench.sh` — phase-boundary wrapper.

### §2.2 What is MISSING for §9.10 as currently written

1. **Cross-runtime comparison infra**. `run_bench.sh` runs only
   `zwasm run …`. It has no concept of "also run wasmtime
   against the same fixture" or "compute the median across
   {zwasm, wasmtime, wazero, wasmer}".
2. **wazero + wasmer not in `flake.nix`** (`grep -n
   "wazero\|wasmer" flake.nix` → 0 matches). Only wasmtime is
   in the dev shell.
3. **`-Dwith-bench-compare` build flag absent**. ADR-0012 §2
   Tier-Optional model wires `hyperfine`, `bun`, `node` under
   this flag; the cross-runtime comparison step is supposed to
   gate on it. The flag has never been added to `build.zig`.
4. **SIMD-specific bench corpus**. `bench/runners/wasm/` is the
   general scalar+SIMD corpus driving §9.8b. No
   per-op-isolated SIMD micro-benches exist (e.g. a fixture
   that exercises *only* `f32x4.add` in a hot loop with the
   neighbouring ops factored out, so the gap is attributable
   to a single op).
5. **Per-op gap analysis script**. No script computes
   `median(wasmtime, wazero, wasmer) → flag ops > 3× v2`.
   The analysis discipline ADR-0043 mandates has zero
   automation surface today.
6. **Phase 15 debt-entry filing template**. ADR-0043 says §9.10
   "files Phase 15 debt entries naming the candidate
   optimisation" — there is no `.dev/debt.md` schema column
   nor an `expected: phase-15-bench-driven` convention to
   distinguish §9.10-surfaced candidates from other Phase 15
   work.

### §2.3 D-074 — formal debt confirming §2.2 above

`.dev/debt.md` D-074 (Status: `blocked-by: no Phase row
currently scheduled for the tier-provisioning machinery;
likely Phase 11 (WASI 0.1 full + bench infra) candidate`)
enumerates the unimplemented ADR-0012 §1–§3 surface:

> Concretely missing: `test/spec/testsuite/` git submodule +
> `test/spec/legacy/` directory (§1 / §3); `versions.lock` +
> `setup_corpora.sh` + `install_tools.ps1` (§2); `bench/{wat,
> custom, embenchen}/` directories (§3); `-Dwith-realworld-
> rebuild` / `-Dwith-realworld-diff` / `-Dwith-bench-compare`
> build flags (§2); `build_realworld.sh` +
> `record_phase_bench.sh` (§1 / §7).

The bench-relevant subset of D-074 (`-Dwith-bench-compare`,
cross-runtime tool install) is the **direct prerequisite of
§9.10 as currently written**. D-074's barrier names Phase 11
as the natural carrier — i.e. §9.10's current scope and
D-074's resolution are tightly coupled.

### §2.4 D-076 — ADR-0043 verify-on-open

`.dev/debt.md` D-076 says: when §9.10 opens inline, verify
that ADR-0043 §"Decision"'s three load-bearing additions
("Per-op gap analysis required", "3× threshold", v1 D122
reference) landed in the row prose. **All three are present
in ROADMAP line 1649** (confirmed by re-reading the row). So
D-076 can discharge as part of whichever §9.10 path is
chosen, in the same chunk that opens the row.

## §3. Scope options

### §3.1 Option (1) — Keep §9.10 as currently written

§9.10 ships the full per-op gap profile against wasmtime +
wazero + wasmer per ADR-0043 §"Decision".

**Prerequisites** (must land BEFORE §9.10 can close):

- D-074's bench-relevant subset: `-Dwith-bench-compare` build
  flag wired in `build.zig`; wazero + wasmer added to
  `flake.nix` Tier-Optional cohort (per ADR-0012 §2); a
  per-runtime adapter shape (e.g.
  `scripts/run_bench_compare.sh` that drives all four
  runtimes through hyperfine).
- A SIMD per-op micro-bench corpus (one fixture per op family,
  factored to attribute timing to a single op). Estimate: ~30
  micro-bench WAT files (one per op family — int binop, FP
  binop, lane ops, mem ops, …). May reuse existing
  `bench/runners/wasm/` shape under a new
  `bench/runners/wasm/simd_microbench/` subdir.
- A gap-analysis script that reads `bench/results/recent.yaml`
  (or a new comparison-oriented YAML), computes
  `median(wasmtime, wazero, wasmer) / zwasm`, flags ops where
  the ratio > 3×, and emits draft debt-entry skeletons.
- A `.dev/debt.md` convention for "Phase 15 bench-driven SIMD
  candidate" rows (column? prefix on Status? tag in Refs?).

**Chunk estimate** (sizing only — not a TTL prediction):

- D-074 bench-relevant subset: ~3 chunks
  (flake.nix + versions.lock + `-Dwith-bench-compare` plumbing
  → comparison runner script → wazero/wasmer fixture format
  compat verification).
- SIMD micro-bench corpus: ~2 chunks (corpus authoring +
  wiring into runner).
- Gap-analysis script + per-op profile run: ~2 chunks.
- Phase 15 debt-entry filing pass: ~1 chunk.
- **Total: ~8 chunks**.

**Commits to / forecloses**:

- ✅ Closes D-074's bench-relevant subset (= the §1–§3 cohort
  most relevant to bench discipline).
- ✅ Produces actionable per-op data that Phase 15 SIMD work
  consumes per ADR-0043 §"Phase 15 amendment".
- ✅ Honours ADR-0043 §"Decision" verbatim — no ADR amendment
  needed.
- ❌ Pushes Phase 9 close out by ~8 chunks (current §9.9
  close itself still pending per Track C resolution).
- ❌ Partially consumes Phase 11's planned scope (D-074 says
  "Phase 11 is the natural carrier"). If Phase 11 was sized
  assuming D-074 still pending at Phase 9 close, this option
  re-shapes Phase 11's surface.

### §3.2 Option (2) — Baseline-only descope; per-op gap moved to Phase 15

§9.10 records the SIMD baseline against wasmtime alone (the
single reference runtime already in `flake.nix`), appends one
phase-9 history.yaml entry, and **defers** per-op gap analysis
to Phase 15 (where SIMD-specific optimisation work would
consume the data anyway).

**Prerequisites**:

- Existing infra already covers this. `scripts/run_bench.sh
  --phase-record --reason="Phase 9 close baseline"` against
  the current corpus produces the baseline against zwasm. A
  parallel wasmtime run can be scripted as a one-off
  comparison (no new build flag; user invokes manually).
- ADR-0043 §"Decision" requires amendment: the "Per-op gap
  analysis required" + "3× threshold" clauses move from §9.10
  to Phase 15. An ADR-0043 §"Amendment log" row covers this.

**Chunk estimate**:

- 1 chunk: §9.10 baseline run + ADR-0043 amendment.

**Commits to / forecloses**:

- ✅ Closes §9.10 in 1 chunk; Phase 9 boundary unblocked.
- ✅ Keeps D-074 intact for Phase 11.
- ✅ Per-op gap analysis still happens — but at Phase 15
  where the optimisation work that consumes it lives. ADR-0032
  bench-driven discipline naturally applies.
- ❌ ADR-0043's load-bearing scope clauses migrate. Not a
  rejection of ADR-0043 — re-homing the *where* (Phase 15 not
  §9.10). Must be reflected in §"Amendment log".
- ❌ Loses one round of "early surfacing": Phase 10
  (GC/EH/tail call/memory64) work proceeds without knowing
  the SIMD gap profile. Probably benign (Phase 10 doesn't
  touch SIMD).

### §3.3 Option (3) — Move §9.10 entirely to Phase 11

§9.10 is removed from Phase 9; the entire row migrates to
Phase 11 alongside D-074's bench infra cohort.

**Prerequisites**:

- ROADMAP §9 amendment: §9.10 row removed; §9.11 (audit pass)
  becomes the new §9.10; §9.12 (open §9.10 inline) becomes
  §9.11. Phase 11's row gains the SIMD per-op gap analysis as
  one of its work items.
- ADR-0043 amendment: §"Decision" §9.10 reference becomes
  Phase 11 reference.

**Chunk estimate**:

- 1 chunk for the ROADMAP migration + ADR amendments.
- Phase 11 absorbs ~8 chunks at its open (parallels
  Option (1) but timed at Phase 11).

**Commits to / forecloses**:

- ✅ Phase 9 closes faster than Option (1); slightly slower
  than Option (2) because of the §9-renumber overhead.
- ✅ All bench infra (D-074 cohort + SIMD gap analysis) lands
  in ONE phase under one coherent design pass. No piecemeal
  half-done state.
- ✅ Aligns with D-074's barrier statement ("Phase 11 is the
  natural carrier").
- ❌ §9-renumber violates ADR-0014 §"no renumber" discipline
  (added precisely because §9.6 renumber attempts caused
  drift). Avoidable by leaving §9.10 as `[~]` "moved to
  Phase 11" without renumber.
- ❌ Phase 10's gate (🔒, GC + EH + tail call + memory64)
  is the largest substrate jump in the roadmap; entering it
  with the SIMD perf story still unmeasured means we
  cannot say "Wasm 2.0 done, Phase 10 begins with a known
  baseline".
- ❌ ADR-0043's framing was specifically "§9.10 produces the
  gap profile that drives Phase 15"; moving the producer to
  Phase 11 lengthens the dependency chain from production to
  consumption (§9.10 → Phase 15 becomes Phase 11 → Phase 15).

## §4. Recommendation

**Option (2) — baseline-only descope, per-op gap analysis
moved to Phase 15.**

Rationale:

1. **Phase 9 close discipline.** Phase 9 is the SIMD-128
   completion phase; its natural exit is "all spec SIMD
   fixtures green". Option (1) couples Phase 9 close to bench
   infra (D-074) that has no other reason to live in Phase 9.
   Option (2) lets Phase 9 close on its own terms.
2. **Bench-driven optimisation discipline already established
   for Phase 15.** ADR-0032 §"§9.8b bench-driven" pattern
   says: optimisation phases consume bench data measured
   inside the same phase. Phase 15 = SIMD-perf phase; running
   the per-op gap measurement at Phase 15 entry (then
   consuming it across the phase's chunks) is the more
   coherent shape than producing it 5 phases earlier.
3. **D-074's natural home is Phase 11.** D-074's barrier
   statement is explicit: "Phase 11 (WASI 0.1 full + bench
   infra) candidate". Folding §9.10's full surface into
   Phase 11 (Option 3) collapses the dependency into one
   phase but at the cost of an §9-renumber that ADR-0014
   forbids. Keeping §9.10 lightweight (baseline only) at
   Phase 9 close is the least disruptive path.
4. **ADR-0043 amendment cost is small.** §"Decision"'s scope
   clauses move from §9.10 to Phase 15. The 3× threshold,
   D122 reference, and AVX/MOVAPS candidate list all stay
   — they just attach to Phase 15 instead of §9.10. The
   amendment is one §"Amendment log" row.
5. **No load-bearing information lost.** A Phase 9 baseline
   run against wasmtime still happens (records to
   history.yaml) — Phase 15 can use it as the "before" point
   for any optimisation gain measurement. The wazero/wasmer
   comparison just slides to Phase 15's bench-driven setup
   step.

**Risks of recommendation**:

- Phase 10's largest-substrate-jump still happens without
  per-op SIMD gap data. **Mitigation**: Phase 10 (GC/EH/tail
  call/memory64) doesn't touch SIMD codegen, so the missing
  data does not block Phase 10 work.
- ADR-0043 amendment is a non-trivial documentation pass
  (§9.10 + Phase 15 row text changes + ADR-0043 §"Decision"
  + §"Amendment log"). **Mitigation**: counted as part of
  the 1-chunk close for Option (2).

## §5. Effect on Tracks B / C / D

- **Track B (D-057 / D-065 source-split partition)** is
  orthogonal — partition decision unaffected.
- **Track C (ADR-0029 path A vs B)** is orthogonal — §9.10's
  scope does not depend on how `skip-impl` / `skip-adr`
  vocabulary resolves.
- **Track D (Phase 10 transition gate doc)** is mildly
  affected: the §9.12 hard-gate row (currently "Open §9.10
  inline + flip phase tracker") reads more cleanly under
  Option (2) (§9.10 is small + 1-chunk) than Option (1)
  (§9.10 is the largest sub-phase). Track D's gate
  checklist should be drafted **after** Track A resolves.

## §6. Open questions for user

1. Does the rationale's premise — "Phase 9's natural exit is
   spec-SIMD-green, bench is orthogonal" — hold? Was §9.10
   originally placed in Phase 9 specifically to surface the
   gap profile while SIMD work was fresh, even at the cost
   of phase-coupling?
2. If Option (2) is accepted: amend ADR-0043 in place
   (§"Amendment log" row) OR write a new ADR-0055
   ("Re-home §9.10 per-op gap analysis to Phase 15")?
   Preference: amend in place (smaller surface, ADR-0043's
   §"Decision" reshape is the central change).
3. D-076 verify-on-open: confirmed ADR-0043's three load-
   bearing additions ARE in ROADMAP §9.10 row prose. If
   Option (2) is accepted, the two "Per-op gap analysis
   required" + "3× threshold" clauses leave §9.10 (move to
   Phase 15) but the D122 reference can stay as historical
   anchor. OK?

## §7. After user decision

- **Option (1) chosen**: open the 8-chunk plan in §9.10
  (ADR-0043 unchanged), proceed normally. D-074
  discharges piecewise across the chunks.
- **Option (2) chosen**: 1 chunk per §3.2 prerequisites.
  ADR-0043 amendment + §9.10 baseline run + Phase 15 row
  amendment + D-076 close land together.
- **Option (3) chosen**: 1-chunk ROADMAP migration; §9.10
  becomes "moved to Phase 11" without renumber; Phase 11
  row absorbs the surface; ADR-0043 §"Decision" §9.10
  reference flips to Phase 11.

Whichever option is chosen, this prep track's outcome must
be reflected in a single follow-up commit (`chore(p10-prep):
track A decision — <option>`) that updates `.dev/handover.md`
to drop "Track A" from the prep-mode `Next candidates` list.

## §8. References

- `.dev/decisions/0012_first_principles_test_bench_redesign.md`
  §1–§3 + Amendment log
- `.dev/decisions/0043_simd_perf_eval_scope.md` §"Decision",
  §"Alternatives" A/B/C
- `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md`
  §"no renumber" discipline
- `.dev/decisions/0032_observability_baseline_substrate.md`
  §9.8b bench-driven pattern
- `.dev/debt.md` D-074, D-076
- `.dev/ROADMAP.md` §9 Phase Status widget (line 1175),
  §9.10 row (line 1649), §9.12 row (line 1651), Phase 11
  row (line 1669)
- `.dev/phase10_prep.md` Track A scope (lines 45–87)
- `bench/README.md`, `scripts/run_bench.sh`,
  `.github/workflows/bench.yml`
