# 0212 — Narrow maintainer approval to product surfaces; retire the standing record duties

- **Status**: Accepted (2026-08-20, maintainer-directed; published for review in discussion #207)
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

Discussion #207 measured the consequence and asked where the maintenance line
should sit, what should become of the debt ledger, and whether the standing
duties could be deleted first. Two of the three were blocked on nothing but the
fact that a prior ADR (ADR-0129, the debt-ledger YAML SSOT) is a maintainer
directive — an apparatus-internal decision gating apparatus-internal work. This
ADR removes that class of gate.

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
| `check_phase10_close_invariants.sh` | deleted | phase-10 close gate; the phase closed 2026-05-24 with phase 9 |
| `check_three_host_diff.sh` | deleted | hardcodes pass totals that already drifted (D-526(5)); the 3-host farm is an optional pre-flight since ADR-0076 D9 |
| `check_wasm_h_upstream.sh` | **kept** | drift detector for `include/wasm.h` against upstream `WebAssembly/wasm-c-api` — a public C ABI guard |
| `check_zig_consumer.sh` | **kept** | proves the public `b.addModule("zwasm")` export stays reachable across a package boundary; its header records why it is deliberately manual (pulls the zlinter dev-dep, D-274) |

Both kept scripts lack a home, not a purpose; giving them one is follow-up
work. ADR-0211 D1 reached the same rule independently a day earlier: deleting
`nightly.yml` left `check_proposal_watch.sh` and `check_spec_bump.sh` with no
automation, and it kept both as on-demand tools rather than deleting them. `check_wasm_h_upstream.sh` compares against a local clone
(`ZWASM_WASM_C_API_PATH`, default `~/Documents/OSS/wasm-c-api`) and SKIPs when
it is absent, so whatever home it gets has to provide that clone.

**D4 — Doc-truth: `wasm-tools` is a build prerequisite.** Measured on a fresh
clone with `wasm-tools` off `PATH`, **bare `zig build` fails**, not merely
`zig build test-all`. The default install step installs
`zwasm-spec-wasm-2-0-assert` (`build.zig:624`), whose module embeds
`spectest.wasm` (`build.zig:606`), so `wasm-tools parse` runs on the
`spectest.wat` → `spectest.wasm` step before anything is installed. The other
two installed spec runners do not import it — un-installing that one exe would
be enough to take `wasm-tools` off the default path. Four living documents claimed otherwise — README ("You only need
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
| **ROADMAP §1 / §1.5 / §2 P10+P11 / §4 A7-A8 / §5 / §11.5 / §13.3 / §14 / row 15.6** | the live normative sections still described the campaign branch model and named the maintainer's SSH hosts as the gate (P11 "all gated locally", A7 "local pre-push gate", A8 "Windows verified via SSH before any release") — contradicting ADR-0076 D9 and, since 2026-08-20, ADR-0211 D3 — working dir `zwasm_from_scratch/`, trunk `zwasm-from-scratch`, "main branch is frozen for v1", and a §14 *inviolable* "❌ Pushing to zwasm-from-scratch without user approval" (an apparatus-internal approval gate D1 deletes) — while CLAUDE.md declares "Conflicts -> ROADMAP wins" | the real tree, and `develop/<slug>` -> PR -> `main` with `ci-required` as the gate. §5's layout tree is rooted at `zwasm/`; §11.5's Windows leg names `ZWASM_WINDOWS_HOST` / `ZWASM_REMOTE_DIR` (ADR-0206) instead of the maintainer's old paths; §1.5 stops pointing "v1 reference" at this repo's own path — v1 is tag `v1.11.1` in this history (D-526(3)) |
| `continue/SKILL.md` per-turn block | step 6 told the agent to `git push origin zwasm-from-scratch`, step 8 made a `ScheduleWakeup` re-arm *mandatory* — live executable instructions for a retired loop | push the `develop/<slug>` branch and open the PR; the loop-era ending kept as one CAMPAIGN-ONLY note |
| `continue/RESUME.md` Step 0.5 | "For every `now`-status entry, attempt discharge before active task" and "Barrier-dissolution check (unconditional, every resume)" — the duty, restated where SKILL.md now links for the *on-demand* capability | sweep-scoped wording; the banner names which steps are on-demand |
| `audit_scaffolding/CHECKS.md` §J.4 | a second, different staleness ladder ("5 resume cycles, 1 cycle ~ 1 day") in the same file as F.2a | both state the script's 14/30-day ladder |
| `scripts/check_lesson_citing.sh` | told the reader to "backfill at the next phase boundary" — a handler that can no longer fire, while the script still WARNs | points at the on-demand audit |
| `.dev/remaining_sweep.md`, `references/handover_doc_discipline.md` | entry points keyed on the per-resume Step 0.5 / 0.5b cadence | on-demand wording |
| `.github/workflows/ci.yml` | the wasm-tools step said "required for test-all" — the same understatement D4 corrects | required for any `zig build` |
| `CLAUDE.md` reference clones | `ClojureWasmFromScratch/` and `~/zwasm/private/v2-investigation/`, neither of which exists on disk | `~/Documents/MyProducts/ClojureWasm/`; dead pointer dropped (D-526(2)) |

A second audit pass, simulating a cold start and following every pointer,
extended the same treatment to:

- **Personal infrastructure stated as procedure.** `.dev/windows_ssh_setup.md`
  and `.dev/ubuntunote_setup.md` were labelled load-bearing and hardwired one
  machine's SSH aliases and `C:\Users\...` paths, while the error messages of
  `run_remote_*.sh` point strangers at them. Both now open by saying the local
  fan-out is optional, that CI is the gate, and that the aliases are examples
  for `ZWASM_{UBUNTU,WINDOWS}_HOST` / `ZWASM_REMOTE_DIR` (ADR-0206).
  `test/README.md` lost its retired-OrbStack rule and its two machine paths.
- **Pointers that did not resolve.** CLAUDE.md cited `docs/migration_v1_to_v2.md`
  (the file is under `.dev/archive/`), claimed an MCP setting `settings.local.json`
  does not contain, and listed three of the five skills. Two `.claude/references/`
  links and one in `debug_jit_auto/SKILL.md` had the wrong `../` depth. The
  `continue` skill and `REWORK.md` cited a **private agent memory** by name as
  the authority for a design priority that ADR-0153 already records.
- **One more approval gate.** `scripts/check_roadmap_amendment.sh` told the
  agent to "ask the user" when unsure which §18 bucket an edit falls in;
  it now says to treat the edit as load-bearing and file the ADR.
- **Closed-phase records marked as live.** Five `.dev/*.md` phase-9/10 planning
  documents carried `Doc-state: ACTIVE` or `DRAFT (uncommitted)` while being
  committed and long closed. They are `ARCHIVED-IN-PLACE`, which is also what
  lets their historical references to the deleted scripts stand without a note
  on every line.

The ROADMAP §1.5 edit is a §18.1 amend-in-place (a superseded directory name),
and this ADR is its §18.2 step 2. ROADMAP §18 needs no other change: it
requires an ADR for load-bearing edits, never maintainer sign-off, so it is
already consistent with D1.

## Alternatives considered

### Alternative A — delete all five caller-less scripts

- **Sketch**: treat "no executing caller" as sufficient grounds on its own.
- **Why rejected**: two of the five guard public surfaces (the C ABI header and
  the Zig package-boundary export). Deleting them trades a documented
  capability for a shorter `scripts/` listing. #207 did not propose this — it
  asked for each to be re-verified in its own deletion PR, which is exactly
  what surfaced the split.

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
- **Negative**: the debt ledger loses its refresh cadence. Two product-side
  defects found between 2026-08-14 and 2026-08-20 arrived through
  cadence-shaped re-verification, and could not be shown independent of it. The
  trade is taken deliberately: directed re-verification is retained, the
  obligation is not.
- **Neutral / follow-ups**:
  - ADR-0206 D5 retained `check_phase{9,10}_close_invariants.sh` because the
    `dispatch_consistency_audit` skill invoked them. Re-verified 2026-08-20:
    it does not, and never did — the skill's only mention is a struck-through
    provenance note, and `git log -S` over that path finds no commit that ever
    added an invocation. A revision note is added to ADR-0206.
  - `check_wasm_h_upstream.sh` and `check_zig_consumer.sh` need a home.
  - Making `zig build` toolchain-free is unresolved. Un-installing
    `zwasm-spec-wasm-2-0-assert` alone would drop `wasm-tools` from the default
    path, but `scripts/wasmtime_misc_sweep.sh` and
    `scripts/wasmtime_misc_native_sweep.sh` consume installed runner binaries.
  - Archiving the closed-phase `.dev/*.md` docs (Alternative B).

## References

- Discussion #207 (the proposal this answers), #201 (the CI-side predecessor),
  ADR-0211 (the CI truth sweep, merged as #203)
- ADR-0129 (debt ledger YAML SSOT — the directive D1 releases), ADR-0206 D5
  (script retention, revised here), ADR-0076 D9 (CI is authoritative),
  ADR-0156 (release stays user-only — unchanged), ADR-0118 (loop scaffolding)
- `.dev/debt.yaml` D-526 (external-contributor reproducibility audit)
