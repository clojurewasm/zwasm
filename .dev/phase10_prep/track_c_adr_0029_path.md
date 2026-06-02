# Phase 10 prep — Track C: ADR-0029 path A vs B (skip semantics)

> **Doc-state**: ARCHIVED-IN-PLACE

> Status: **DECIDED — Path B + all 5 sub-decisions confirmed**
> (Q1=Path B, Q2=warning+count, Q3=filename stub, Q4=defer
> (c)-path to Phase 10/11 with accountable new debt D-082,
> Q5=pre-commit gate). See §8 for resolved questions, §9 for
> decision record.
> Decision date: 2026-05-12 (user-confirmed in prep mode session)
> Date: 2026-05-12
> Author: autonomous `/continue` loop, Phase 10 prep mode
> Path note: relocated from `private/notes/p10-prep-track-c-…`
> to `.dev/phase10_prep/` per Track A/B precedent.

## §1. Question

**Does §9.9's `skip = 0` exit criterion mean literally zero
SKIPs, or zero `skip-impl` with `skip-adr` waived by design?**

ADR-0029 §"Decision" specifies the second interpretation
(implementation gaps count; proposal-skip ADRs do not) but the
implementation classifies via **hardcoded reason-string mapping
in `spec_assert_runner.zig:103-108`** instead of the
ADR-prescribed **manifest-line prefix vocabulary**
(`skip-impl <field>` / `skip-adr-<ADR-id> <field>`). The ADR's
Revision History acknowledges this as design↔implementation
divergence; D-073 explicitly names the binary choice that this
Track resolves.

## §2. Evidence — current state

### §2.1 Live SIMD skip breakdown (2026-05-12)

`bash scripts/p9_simd_status.sh` reports (Mac host, the
authoritative live measurement):

> `simd_assert_runner: 11384 passed, 0 failed, 2357 skipped`

Breakdown by reason (extracted from runner output + prep doc):

| Reason                                | Count | Category (per ADR-0029) | Driver                                                  |
|---------------------------------------|-------|-------------------------|---------------------------------------------------------|
| `nan-or-bad-token`                    | 1222  | impl-gap (cat. 1)        | NaN-aware comparison not implemented (regen-script skip; impl gap) |
| `v128-param-pending`                  |  788  | impl-gap (cat. 1)        | More entry helpers needed (mechanical impl gap)         |
| `directive-assert_malformed-text`     |  390  | proposal-adr (cat. 2)    | Text-format parser scope-out per `skip_text_format_parser.md` |
| `assert_trap-v128-pending`            |   18  | impl-gap (cat. 1)        | v128-result assert_trap runner gap                       |
| `export-name-has-spaces`              |    3  | impl-gap (cat. 1)        | Tokenizer quirk; impl gap                               |

- **Impl-gap total**: 2031 (drives §9.9 / 7.5-equivalent gate)
- **Proposal-adr total**: 390 (waived by ADR-0029 §"Decision")

(2357 = sum of above with overlap noise — the structural split
is what matters, not the exact numbers.)

### §2.2 ADR-0029 design vs. implementation divergence

**ADR §"Decision" (load-bearing vocabulary)**:

> Each manifest-line `skip` directive consumed by
> `spec_assert_runner` / `wast_runner` carries one of two
> prefixes:
>
> - `skip-impl <field>` — counted; non-zero blocks `[x]` flip.
> - `skip-adr-<ADR-id> <field>` — not counted; reported in
>   separate `proposal_skipped` tally.

**Implementation reality** (`spec_assert_runner.zig:102-113`):

```zig
if (std.mem.startsWith(u8, line, "skip ")) {
    // skip-adr classification — `directive-assert_malformed-text`
    // is covered by `.dev/decisions/skip_text_format_parser.md`
    // and counts as skip-adr (not skip-impl) per ADR-0029.
    // Other skip reasons remain skip-impl until ADR-promoted.
    const reason = line[5..];
    if (std.mem.eql(u8, reason, "directive-assert_malformed-text")) {
        skipped_adr.* += 1;
    } else {
        skipped.* += 1;
    }
    continue;
}
```

- **Manifests carry bare `skip <reason>` lines** (no prefix).
  `grep -rn "skip-impl\|skip-adr" test/spec/` returns 0 matches
  (D-073 baseline confirmed).
- **Single hardcoded mapping**: only
  `directive-assert_malformed-text` → skip-adr; all other
  reasons → skip-impl.
- **Regen scripts emit bare `skip` lines**:
  `scripts/regen_spec_simd_assert.sh:241-289` emits e.g.
  `skip v128-param-pending {field}`, `skip
  directive-assert_malformed-text`, etc.

### §2.3 The two skip-ADRs currently mapped

| skip-ADR file                                            | Implementation status                                              |
|----------------------------------------------------------|--------------------------------------------------------------------|
| `.dev/decisions/skip_text_format_parser.md`              | ✅ Mapped (`directive-assert_malformed-text` reason string)         |
| `.dev/decisions/skip_embenchen_emcc_env_imports.md`      | ❌ NOT effective per ADR-0050 D-2 (no runner classification)        |
| `.dev/decisions/skip_externref_segment.md`               | ❌ NOT effective per ADR-0050 D-2 (no runner classification)        |

D-072 tracks the latter two (separate from D-073's vocab choice,
but related; see §6 below).

### §2.4 What D-072 / D-073 / D-076 each track

| Debt  | Scope                                                                                   | Closes via Track C? |
|-------|-----------------------------------------------------------------------------------------|---------------------|
| D-072 | `wast_runtime_runner.zig` skip-token enforcement for 5 wasmtime_misc fixtures           | Partial (Path B closes ADR-vocab; runner change still needed for the runtime runner) |
| D-073 | ADR-0029 design↔impl divergence; pick (a) amend ADR vs. (b) migrate to prefix vocab     | **Yes, this Track resolves D-073 directly** |
| D-076 | ADR-0043 §9.10 row-prose verify-on-open                                                  | No — already Track A's domain (verified inline) |

## §3. Path A — amend ADR-0029 to match implementation

§"Decision" rewrites the prefix vocabulary clause to describe
the runner-internal hardcoded mapping. ADR-0029 stays
`Accepted`; D-073 closes because the divergence becomes
"design recognises implementation reality".

### §3.1 Mechanism after Path A

- Manifests stay with bare `skip <reason>` lines.
- New skip-ADRs (e.g. when Phase 10 deferrals start landing) add
  the reason string to `spec_assert_runner.zig:103-108`'s
  switch-statement-equivalent code.
- §9.9 close gate flips when `failed = skip-impl = 0` per the
  runner's twin tally (already in place).

### §3.2 Concrete edits

1. **ADR-0029 §"Decision" rewrite**:
   - Remove "Each manifest-line `skip` directive consumed by
     `spec_assert_runner` / `wast_runner` carries one of two
     prefixes:" paragraph.
   - Add "Classification is runner-internal: each runner
     maintains a hardcoded mapping from reason-string to
     {`skip-impl`, `skip-adr-<ADR-id>`}. Adding a new
     proposal-skip ADR requires (a) authoring the
     `.dev/decisions/skip_*.md` file, (b) adding the reason
     string to the runner's mapping function, (c) updating
     `scripts/regen_spec_*.sh` to emit that reason string
     when the directive applies."
   - Keep the §"Operationally" paragraph's output-format
     evolution (twin tally) — already implemented.
2. **ADR-0029 §"Amendment log" row**:
   > 2026-05-XX | `<backfill>` | Path A discharge of D-073:
   > formalize runner-internal hardcoded reason-string
   > classification as the load-bearing mechanism. Manifest-line
   > prefix vocabulary (`skip-impl` / `skip-adr-<ADR-id>`)
   > removed from the design surface; the operational outcome
   > (twin-tally output + deterministic `[x]`-flip rule) was
   > delivered via the actually-shipped path.
3. **D-073 close**: same commit deletes the row from
   `.dev/debt.yaml`.

### §3.3 Path A cost / closes / new debt

| Aspect            | Detail                                                                |
|-------------------|-----------------------------------------------------------------------|
| Chunks            | **1 chunk**                                                            |
| LOC delta         | ~30 LOC ADR text + 1 D-073 row deletion                                |
| What closes       | D-073                                                                  |
| What still needs work | D-072 (wast_runtime_runner classification — separate change)        |
| New debt opens    | None directly; D-072's "design choice between (a) / (b)" line gets simplified — (b) is no longer ADR-supported, so D-072 effectively narrows to "(a) extend handleModule + (c) actual fixes" |
| §9.9 close impact | None on the gate flip itself (the runner already classifies; the criterion `failed = skip-impl = 0` already evaluates correctly) |

### §3.4 Path A weakness

- **Adding a new skip-ADR requires runner-code edits forever**.
  When Phase 10 brings new proposal-skip ADRs (GC, EH, tail-call
  deferrals), each needs (a) ADR file + (b) reason-string
  registration in `spec_assert_runner.zig` (and any other
  runner). This is the structural barrier ADR-0029 originally
  tried to avoid.
- **Manifests are not self-documenting**: reading a manifest's
  `skip <reason>` line, one must consult the runner's mapping
  code to know whether it counts toward the gate. The ADR's
  original design made manifests speak for themselves.

## §4. Path B — migrate to prefix vocabulary

The full ADR-0029 design lands: regen scripts emit prefix-vocab
lines; runners parse the prefix; existing manifests migrate via
regen sweep; skip-ADRs are authored without runner-code edits.

### §4.1 Mechanism after Path B

- Manifests carry `skip-impl <reason>` or `skip-adr-<ADR-id>
  <reason>` lines.
- Runners parse the prefix → tally directly (no reason-string
  switch).
- Adding a new skip-ADR:
  1. Author `.dev/decisions/skip_<topic>.md`.
  2. Update `scripts/regen_spec_*.sh` to emit `skip-adr-<topic>
     <reason>` for fixtures the ADR covers.
  3. Re-run regen; commit the manifest deltas.
  No runner-code changes.

### §4.2 Concrete edits

1. **Runner updates** (~30 LOC each):
   - `test/spec/spec_assert_runner.zig:102-113`: replace
     hardcoded-mapping branch with prefix-detection
     (`startsWith "skip-impl "` / `startsWith "skip-adr-"`).
     Add backward-compat: bare `skip <reason>` → emit warning
     line + count as skip-impl.
   - `test/runners/wast_runner.zig`: parallel change (if it
     has skip handling).
   - `test/runners/wast_runtime_runner.zig`: same; **this
     incidentally provides the (b) discharge path for D-072**
     because the new prefix-aware runner can recognise
     `skip-adr-skip_embenchen_emcc_env_imports` /
     `skip-adr-skip_externref_segment` directives.
2. **Regen script updates** (~20 LOC each):
   - `scripts/regen_spec_simd_assert.sh:241-289`: change
     `skip nan-or-bad-token` → `skip-impl nan-or-bad-token`;
     `skip directive-assert_malformed-text` →
     `skip-adr-skip_text_format_parser
     directive-assert_malformed-text`; etc.
   - `scripts/regen_spec_1_0_assert.sh`: parallel.
3. **Manifest migration**: re-run regen scripts; commit deltas.
   For non-regenerated manifests (one-off
   `test/wasmtime_misc/wast/*/manifest_runtime.txt`), hand-
   prefix the lines.
4. **Existing 3 skip-ADRs** (`skip_text_format_parser.md`,
   `skip_embenchen_emcc_env_imports.md`, `skip_externref_
   segment.md`): add a §"Implementation" subsection naming the
   manifest prefix vocabulary used.
5. **`scripts/check_skip_adrs.sh`** (if exists per ADR-0050
   D-3) extended to verify prefix-vocab coherence (every
   `skip-adr-<id>` references an existing ADR file; every
   skip-ADR has at least one prefix consumer).
6. **D-073 close**: row deleted from `.dev/debt.yaml`.

### §4.3 Path B cost / closes / new debt

| Aspect            | Detail                                                                |
|-------------------|-----------------------------------------------------------------------|
| Chunks            | **3-4 chunks**: (1) runner prefix-parsing + back-compat warning; (2) regen scripts + manifest sweep; (3) wast_runtime_runner prefix support + 3 skip-ADR Implementation §; (4) optional: `check_skip_adrs.sh` extension |
| LOC delta         | ~150 LOC code + ~500 LOC manifest deltas (auto-regenerated) + ~50 LOC ADR text updates |
| What closes       | **D-073 + D-072's (b) path discharge (the latter via wast_runtime_runner becoming prefix-aware)** |
| What still needs work | D-072's (c) path ("actual fixes" for the 5 wasmtime_misc fixtures) remains as separate work — but the runner-side enforcement closes |
| New debt opens    | Migration debt if any manifest is missed; mitigated by `check_skip_adrs.sh` gate |
| §9.9 close impact | Same operational outcome as Path A (twin tally; gate flips on skip-impl=0). Path B makes the **mechanism** self-documenting |

### §4.4 Path B strength

- **New skip-ADR workflow is runner-code-free**. Phase 10's
  expected GC / EH / tail-call deferrals only need ADR + regen
  edits. This matches the autonomous-loop discipline (loop adds
  ADR rows; not runner-code edits per ADR).
- **Manifests self-document**: reading a manifest line tells
  you whether it's gate-counted (`skip-impl`) or waived
  (`skip-adr-<id>`).
- **D-072 partial discharge piggybacks**: the wast_runtime_
  runner enforcement gap closes when the runtime runner becomes
  prefix-aware — one chunk knocks out two debts.

### §4.5 Path B weakness

- **Higher implementation cost** (3-4 chunks vs Path A's 1).
- **Manifest churn**: ~500 LOC of regen-driven diff. Most is
  auto-generated, but the diff is large and reviewers must
  trust the regen script's correctness.
- **Migration risk**: one-off manifests
  (`test/wasmtime_misc/wast/*/manifest_runtime.txt`) need
  hand-migration. Easy to miss a line; gate addition
  (`check_skip_adrs.sh`) mitigates.

## §5. Recommendation

**Path B — migrate to prefix vocabulary.**

Rationale (Track A/B precedent consistency):

1. **No-drift principle**. Track A (Option 3) and Track B (4-way
   split + suffix naming + tiered pub) both chose the
   structurally-correct path even when the easier path was
   available. Path B is the analogous choice for Track C.
2. **Phase 10 readiness**. Phase 10 will bring new proposal-skip
   ADRs (GC opcodes that aren't yet validator-supported, EH
   opcodes deferred for runtime work, tail-call opcodes whose
   IR ZirOp catalogue isn't decided, memory64 opcodes whose
   addressing ABI isn't ported). Path A makes each new ADR
   require a runner-code edit; Path B makes ADR + regen the
   only changes. Phase 10's surface is large enough that this
   workflow difference matters.
3. **Honest design**. ADR-0029's original design was correct
   (the manifest-vocabulary approach IS more self-documenting
   and less coupled). The implementation took a shortcut
   because the prefix vocab wasn't there at the time. Path B
   pays the deferred cost; Path A acknowledges the shortcut
   permanently.
4. **D-072 partial discharge bonus**. Path B's wast_runtime_
   runner change knocks D-072's (a/b) path open. That's free
   leverage of work we're doing anyway.
5. **Migration risk is bounded**. The regen scripts are
   authoritative; one-off manifests are 2-3 files
   (`test/wasmtime_misc/wast/{embenchen,reftypes}/manifest_
   runtime.txt`). The `check_skip_adrs.sh` gate catches any
   miss.

**Risks of Path B that mitigate to acceptance**:

- 3-4 chunks of work: ~6-10h of autonomous loop time.
  Acceptable given Phase 10 entry leverage.
- Manifest diff is large: ~500 LOC auto-generated. Reviewer can
  verify by diffing the regen output before/after.

## §6. Implementation chunks — Path B (DECIDED)

Per `phase10_prep.md` §"After all 4 tracks complete", actual
implementation fires after Track D decision lands too. Path B
chunk sequence (4 chunks):

| Chunk        | Scope                                                                                                                                                                                                                                                                                       | Risk          |
|--------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------|
| 9.9-h-21     | `spec_assert_runner.zig` + `wast_runner.zig` (if applicable): prefix-detection logic (`startsWith "skip-impl "` / `startsWith "skip-adr-"`) + bare-`skip` back-compat **warning + count as skip-impl** (Q2). Test gate green. **No manifest changes yet** — runner accepts both forms.        | medium (runner change with both forms working) |
| 9.9-h-22     | Update `scripts/regen_spec_simd_assert.sh` + `scripts/regen_spec_1_0_assert.sh` to emit prefix-vocab lines (e.g. `skip-impl nan-or-bad-token <field>`, `skip-adr-skip_text_format_parser directive-assert_malformed-text` per Q3 filename-stub convention); re-run regen; commit manifest deltas. ~500 LOC auto-generated. | medium (large diff, but mechanical) |
| 9.9-h-23     | `wast_runtime_runner.zig` prefix-aware migration; hand-migrate `test/wasmtime_misc/wast/{embenchen,reftypes}/manifest_runtime.txt` to prefix vocab. **D-072 (a/b)-path discharge** + the 2 currently-NOT-EFFECTIVE skip-ADRs (`skip_embenchen_emcc_env_imports.md`, `skip_externref_segment.md`) gain effective runner enforcement. **File new debt D-082 for (c)-path actual-fixture-fixes** (see §6.1 for accountable scope). | medium |
| 9.9-h-24     | ADR-0029 §"Amendment log" row recording Path B closure; update existing 3 skip-ADRs to reference prefix vocab in new §"Implementation" subsection; **extend `scripts/check_skip_adrs.sh` as `.githooks/pre-commit`-invoked gate (Q5)** — coherence checks: every `skip-adr-<id>` references existing skip-ADR; every skip-ADR has ≥1 manifest consumer; D-073 close + D-072 (a/b)-status update to "closed (vocab path); (c)-path moved to D-082". | low |

Total: 4 chunks. Sequencing requires Track A/B/D
implementation chunks to NOT interleave (autonomous loop runs
each track's implementation in order).

### §6.1 Deferral accountability — new debt D-082 (Q4 discharge spec)

Q4 defers D-072 (c)-path (actual root-cause fixes for the 5
wasmtime_misc fixtures) out of Phase 9 scope. Per the user's
"先送り先で責任をもって解消" principle, the deferral lands as
**new debt D-082** in chunk 9.9-h-23 with the following
load-bearing spec:

**D-082 row body** (drafted; lands in chunk 9.9-h-23):

> **D-072 (c)-path: actual root-cause fixes for 5 wasmtime_misc
> realruntime fixtures**. Path B's vocab migration (9.9-h-23)
> discharged the runner-side enforcement gap; the 5 fixtures
> now correctly skip via prefix-vocab. This debt tracks the
> downstream task: **actually fix the fixtures** so the skip
> ADRs can retire.
>
> **Sub-row (a) — 4 embenchen fixtures** (`skip_embenchen_emcc_
> env_imports.md` scope):
>   - Status: `blocked-by: Phase 11 embenchen full-perf-suite scope per ADR-0012 §6 "Out of Phase-6 scope" table`
>   - Discharge trigger: when Phase 11 opens the embenchen
>     full-perf-suite work item, these 4 fixtures' `emcc env
>     imports` shim work lands as part of that cohort. Retire
>     `skip_embenchen_emcc_env_imports.md` in the same chunk
>     (delete the file, remove prefix lines from manifest).
>   - Refs: `skip_embenchen_emcc_env_imports.md`, ADR-0012 §6,
>     ROADMAP Phase 11 row.
>
> **Sub-row (b) — 1 externref segment fixture** (`skip_
> externref_segment.md` scope):
>   - Status: `blocked-by: externref segment bug root-cause investigation; Phase 11 candidate (alongside embenchen cohort) OR earlier if a related reftype handler change in Phase 10 surfaces it`
>   - Discharge trigger: case-by-case. If Phase 10 GC work
>     touches externref segment handling, fix in the same
>     chunk and retire the skip-ADR. Otherwise defer to Phase
>     11 alongside (a). Re-evaluate barrier on every resume
>     per `/continue` Step 0.5 (no "vague blocked-by" allowed;
>     when Phase 10 GC opens, walk this row's barrier).
>   - Refs: `skip_externref_segment.md`, ADR-0050 D-2 (the
>     effectiveness-test that surfaced the original NOT
>     EFFECTIVE state).
>
> **Refs (shared)**: D-072 (closes (a/b)-path at chunk
> 9.9-h-23; this row inherits the (c)-path scope), ADR-0029,
> ADR-0050, ADR-0012 §6.

This means **the deferral is committed as a row that the
autonomous loop's per-resume Step 0.5 will re-evaluate every
session**. Both sub-rows have concrete barriers with named
discharge triggers; no "TBD" or "later" phrasing.

### §6.2 Back-compat warning lifecycle

Q2 chose "warning + count as skip-impl" for bare `skip <reason>`
lines. The warning's purpose evolves across the migration:

- **During 9.9-h-21 → 9.9-h-22 transition**: warning fires on
  every manifest line (manifests not yet regen'd). Expected
  noise; gate stays green because skip-impl counts are
  preserved.
- **After 9.9-h-22 + 9.9-h-23**: warning should fire on 0
  lines (regen sweep + hand-migration complete). If any
  warning fires post-9.9-h-23, that's a missed migration —
  catch via the `check_skip_adrs.sh` gate added in 9.9-h-24.
- **Phase 10+**: warning remains as forward-compat protection
  against future hand-authored manifests that forget the
  prefix. No removal trigger — permanent feature.

## §7. Effect on Track D + Phase 10 entry

- **Track D (Phase 10 transition gate doc)** §3 "design
  cleanliness extrapolation" checklist should include
  "ADR-0029 path resolved; prefix vocab adopted; D-073 closed"
  as one exit checkbox. Path B chosen → checkbox flips ☑ when
  9.9-h-24 lands. Path A → checkbox is "N/A: divergence
  acknowledged in ADR amendment".
- **Phase 10 entry workflow**: under Path B, the loop can land
  GC/EH/tail-call/memory64 skip-ADRs with ADR + regen edits
  only. Under Path A, every new skip-ADR is one extra runner-
  code edit chunk. Multiplying by ~5-10 anticipated Phase 10
  deferral ADRs, Path B saves ~5-10 chunks of work over the
  phase lifetime.

## §8. Resolved questions

1. **Path A vs Path B**: **Path B** (no-drift principle,
   Phase 10 workflow benefit, D-072 (a/b) piggyback discharge).
2. **Back-compat warning behaviour**: warning + count as
   skip-impl. Permanent feature (forward-compat protection); no
   removal trigger. See §6.2 for warning-lifecycle.
3. **ADR-id format**: filename stub (e.g.
   `skip-adr-skip_text_format_parser` references
   `.dev/decisions/skip_text_format_parser.md`). Matches existing
   `skip_*.md` naming convention.
4. **D-072 (c)-path sequencing**: defer to Phase 10/11 via
   **new debt D-082** with two sub-rows: (a) 4 embenchen
   fixtures → Phase 11 (ADR-0012 §6 cohort), (b) 1 externref
   fixture → Phase 11 default, Phase 10 if GC reftype work
   surfaces it. See §6.1 for the load-bearing D-082 spec.
5. **Skip-ADR check gate**: extend `scripts/check_skip_adrs.sh`
   as `.githooks/pre-commit`-invoked gate. Lands in chunk
   9.9-h-24 alongside the prefix-vocab final-state checks.

## §9. Decision record

| Date       | Decision                                                                                                                          | Recorded by              |
|------------|-----------------------------------------------------------------------------------------------------------------------------------|--------------------------|
| 2026-05-12 | Q1=Path B (migrate to prefix vocab), Q2=warning+count, Q3=filename stub, Q4=defer (c)-path via D-082, Q5=pre-commit gate          | user (prep mode session) |

## §10. References

- `.dev/decisions/0029_spec_test_skip_semantics.md` (this
  Track's source ADR; §"Decision" + Revision History 2026-05-11
  divergence acknowledgement)
- `.dev/decisions/skip_text_format_parser.md` (only currently
  mapped skip-ADR)
- `.dev/decisions/skip_embenchen_emcc_env_imports.md`,
  `skip_externref_segment.md` (NOT EFFECTIVE per ADR-0050 D-2;
  Path B's wast_runtime_runner migration discharges them)
- `.dev/decisions/0050_*.md` D-2 (three-path effectiveness test)
- `.dev/debt.yaml` D-072, D-073
- `test/spec/spec_assert_runner.zig:48-71` (twin-tally output),
  `:102-113` (hardcoded reason mapping)
- `scripts/regen_spec_simd_assert.sh:241-289` (skip directive
  emission)
- `scripts/regen_spec_1_0_assert.sh:105` (parallel; wasm-1.0
  side)
- `.dev/phase10_prep.md` §"Track C"
- `.dev/phase10_prep/track_a_9.10_scope.md`,
  `.dev/phase10_prep/track_b_source_split.md` (sibling prep
  deliverables — precedent for no-drift path choices)
