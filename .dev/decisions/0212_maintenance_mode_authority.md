# 0212 — Narrow maintainer approval to product surfaces; retire the standing record duties

- **Status**: Proposed (becomes Accepted when the maintainer answers discussion #207)
- **Date**: 2026-08-20
- **Author**: chaploud
- **Tags**: process, governance, records, docs

## Context

zwasm moved from single-maintainer development to multi-person development on
a public support line. The `.dev/` + `.claude/` corpus — 211 ADRs, 193 lessons,
a 3,053-line debt ledger, 21 path-scoped rules — was built to make an
autonomous agent campaign work (4,513 commits in 2026-05, peak 367/day). The
agent bore its read and write cost. That campaign is retired; the cost now
falls on maintainer sessions with nothing to amortize it.

Discussion #207 measured the consequence and asked three questions. Two of them
are blocked on nothing but the fact that a prior ADR (ADR-0129, the debt-ledger
YAML SSOT) is a maintainer directive — an apparatus-internal decision gating
apparatus-internal work. This ADR removes that class of gate.

The records are development scaffolding, not product. Where they are wrong,
they are corrected or deleted; where a decision they carry no longer holds, it
is superseded without ceremony.

## Decision

**D1 — Approval scope.** Maintainer sign-off is required for four things:
product semantics, public claims, releases (unchanged: ADR-0156), and gate
definitions. Nothing apparatus-internal requires it. Any ADR, ledger row,
lesson, rule, skill, or handover file that describes the development apparatus
may be amended, superseded, or deleted by any maintainer without prior
sign-off — including this one and ADR-0129.

**D2 — The standing record duties are retired.** Deleted: the ledger's header
duty line, the `conventions:` block's "refresh on every resume" and "discharge
every `now` entry" statements, and CLAUDE.md's "refresh per `/continue` Step
0.5" clause. A fourth instance not named in #207 is retired with them: the
`Last reviewed` bullet's resume-cycle staleness mechanism, which fired
`audit_scaffolding` from a loop that no longer exists. The `Last reviewed`
column itself stays — a stale barrier should be visible as a date — and the
Step-0.5 procedure text stays as an opt-in audit capability.

**D3 — A caller-less check is deleted only when its capability is used up.**
Absence of an executing caller is the trigger to look, not the verdict. Of the
five scripts #207 identified, three are used up and are deleted here; two guard
a live public surface and are kept:

| Script | Verdict | Reason |
|---|---|---|
| `check_phase9_close_invariants.sh` | deleted | phase-9 close gate; the phase closed 2026-05-24 |
| `check_phase10_close_invariants.sh` | deleted | phase-10 close gate; the phase closed |
| `check_three_host_diff.sh` | deleted | hardcodes pass totals that already drifted (D-526(5)); the 3-host farm is an optional pre-flight since ADR-0076 D9 |
| `check_wasm_h_upstream.sh` | **kept** | drift detector for `include/wasm.h` against upstream `WebAssembly/wasm-c-api` — a public C ABI guard |
| `check_zig_consumer.sh` | **kept** | proves the public `b.addModule("zwasm")` export stays reachable across a package boundary; its header records why it is deliberately manual (pulls the zlinter dev-dep, D-274) |

Both kept scripts lack a home, not a purpose. Giving them one is follow-up work.

**D4 — Doc-truth: `wasm-tools` is a build prerequisite.** Measured on a fresh
clone with `wasm-tools` off `PATH`, **bare `zig build` fails**, not merely
`zig build test-all`: three spec-runner executables are `installArtifact`-ed,
so the default install step pulls in the `spectest.wat` → `spectest.wasm`
generation. Four living documents claimed otherwise — README ("You only need
Zig 0.16.0"), CONTRIBUTING ("needs nothing else"), `docs/development.md`
(wasm-tools listed *optional*; "no toolchain beyond Zig") and `docs/tutorial.md`
— and so did the ledger row that was supposed to be tracking the gap
(D-526(1) claimed "only `zig build test` is truly toolchain-free"). All five are
corrected. Removing the dependency instead is a separate decision: two sweep
scripts consume the installed runner binaries.

**D5 — The scaffolding is made to agree with D1-D4 in the same change.**
Deleting a duty statement while a live document still issues the duty moves
one copy of a fact and leaves the other — the failure mode this whole line of
work is about. Audited and corrected here:

| Where | What it said | Now |
|---|---|---|
| `continue/SKILL.md` resume procedure | Step 0.5 debt sweep was step 5 of the mandatory sequence — the duty D2 deletes | Steps 0.5 / 0.5b / 0.6 / 0.7 moved to an explicit on-demand block; the mandatory list keeps handover, lesson scan, git state, tests, status |
| `continue/SKILL.md` §Stop conditions, §Phase boundary | live-voiced campaign machinery: a stop whitelist for an autonomous loop, a handler keyed on `§9.<N>` rows | CAMPAIGN-ONLY markers (D-526(4), partial) |
| `audit_scaffolding/SKILL.md` | "Mandatory (the loop fires this skill automatically)" — a phase-boundary trigger needing an open phase, and a stale-debt trigger needing the Step-0.5 cadence | on-demand, pointing at `scripts/audit_blocked_by_age.sh`, which is the surviving mechanized half |
| `audit_scaffolding/CHECKS.md` F.2a | a "resume cycles" ladder, and "to be authored as a follow-up" for a script that exists | calendar-day ladder matching the script; the script named as the reference implementation |
| `dispatch_consistency_audit/SKILL.md` | "Fires at periodic audit_scaffolding boundaries" | on request, or with audit_scaffolding when the substrate is in scope |
| **ROADMAP §1.5** | working directory `zwasm_from_scratch/` and branch `zwasm-from-scratch`, both retired — while CLAUDE.md declares "Conflicts -> ROADMAP wins" | `~/Documents/MyProducts/zwasm/`, and the `develop/<slug>` -> PR -> `main` flow (D-526(3)) |
| `CLAUDE.md` reference clones | `ClojureWasmFromScratch/` and `~/zwasm/private/v2-investigation/`, neither of which exists on disk | `~/Documents/MyProducts/ClojureWasm/`; dead pointer dropped (D-526(2)) |

The ROADMAP §1.5 edit is a §18.1 amend-in-place (a superseded directory name),
and this ADR is its §18.2 step 2. ROADMAP §18 needs no other change: it
requires an ADR for load-bearing edits, never maintainer sign-off, so it is
already consistent with D1.

## Alternatives considered

### Alternative A — delete all five caller-less scripts

- **Sketch**: treat "no executing caller" as sufficient grounds, as #207 reads.
- **Why rejected**: two of the five guard public surfaces (the C ABI header and
  the Zig package-boundary export). Deleting them trades a documented
  capability for a shorter `scripts/` listing. The finding only appears on
  reading each script, which is why #207 asked for per-script re-verification.

### Alternative B — archive the closed-phase `.dev/*.md` planning docs

- **Sketch**: `check_doc_fossils`'s own remedy line offers "move a historical
  doc under `.dev/archive/`", and ~20 phase-9/10 planning docs sit at `.dev/`
  top level with Doc-state markers that no longer hold (two say "DRAFT
  (uncommitted)" while committed).
- **Why rejected here**: they are cited from `src/`, from ADRs 0109-0117, and
  from the phase log; moving them is a link sweep that would dominate this
  diff. The dead references are instead corrected in place with dated notes.
  The archive move remains worth doing on its own.

### Alternative C — make the ledger's duty statements descriptive rather than deleting them

- **Sketch**: keep the text, reword from obligation to description.
- **Why rejected**: a duty statement reworded is still read as a duty. The
  procedure it invoked survives in the continue skill, which is where someone
  who wants the audit will look.

## Consequences

- **Positive**: the apparatus stops requiring the maintainer. Four public
  documents stop making a false build claim that a first-time contributor hits
  on their first command.
- **Negative**: the debt ledger loses its refresh cadence. #207 measured two
  product-side catches this week that came through cadence-shaped
  re-verification and could not show they were independent of it. The trade is
  taken deliberately: directed re-verification is retained, the obligation is not.
- **Neutral / follow-ups**:
  - ADR-0206 D5 retained `check_phase{9,10}_close_invariants.sh` because the
    `dispatch_consistency_audit` skill invoked them. Re-verified 2026-08-20:
    it does not, and never did — the skill's only mention is a struck-through
    provenance note. A revision note is added to ADR-0206.
  - `check_wasm_h_upstream.sh` and `check_zig_consumer.sh` need a home.
  - Making `zig build` toolchain-free (un-installing the three spec-runner
    exes, or generating `spectest.wasm` without `wasm-tools`) is unresolved;
    `scripts/wasmtime_misc_native_sweep.sh` and `scripts/wasmtime_misc_sweep.sh`
    consume the installed binaries.
  - Archiving the closed-phase `.dev/*.md` docs (Alternative B).

## References

- Discussion #207 (the proposal this answers), #201 (the CI-side predecessor),
  PR #203 (ADR-0211, the CI truth sweep)
- ADR-0129 (debt ledger YAML SSOT — the directive D1 releases), ADR-0206 D5
  (script retention, revised here), ADR-0076 D9 (CI is authoritative),
  ADR-0156 (release stays user-only — unchanged), ADR-0118 (loop scaffolding)
- `.dev/debt.yaml` D-526 (external-contributor reproducibility audit)
