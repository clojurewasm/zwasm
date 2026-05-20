# 0049 — Defer windowsmini gate to Phase-close batch reconciliation

- **Status**: Accepted
- **Date**: 2026-05-11
- **Author**: project owner (kudo) + autonomous-loop scribe
- **Tags**: testing-gate, autonomous-loop, multi-host-policy

## Context

ROADMAP §A13 ("merge gate is three-host: Mac aarch64 + OrbStack
Ubuntu x86_64 + windowsmini") + the `/continue` autonomous loop's
per-chunk gate (`scripts/should_gate_windows.sh` heuristic) make
windowsmini a co-equal gate alongside Mac + OrbStack. In practice
the windowsmini gate is the wall-clock dominant cost of the
autonomous loop — a single run takes ~10-15 min and the heuristic
fires it every 4-10 commits. Across the hundreds of chunks Phase
9 has shipped, the cumulative windowsmini wait dominated real
progress disproportionately to the rate of unique-to-windowsmini
findings.

The vast majority of zwasm v2 code is currently architecture-
agnostic (parser, validator, lower, IR, runtime); architecture-
specific code lives in `src/engine/codegen/{arm64,x86_64}/`. ARM64
NEON is exercised by Mac (host); x86_64 SSE/SSE4.x is exercised by
OrbStack (Linux x86_64). Windows x86_64 specificity is largely
ABI (Win64 calling convention) + WASI fd dispatch + occasional
linker / process-launch quirks. These are real but their
historical surfacing rate inside the autonomous loop is low
relative to the gate's per-cycle cost.

The user surfaced this as a clear development bottleneck on
2026-05-11 and requested an ADR-grade policy change.

## Decision

**Inside the autonomous `/continue` loop, treat the windowsmini
gate as deferred — never fire it per-chunk, regardless of the
`should_gate_windows.sh` heuristic.** Mac (foreground) + OrbStack
(background) two-host gate is the per-chunk default. The
windowsmini gate is replaced by a **batch reconciliation phase
at Phase boundaries** — a new ROADMAP-level step that runs
windowsmini once at Phase close, debugs any accumulated failures
together, and closes them as a single tracked work item before
the next phase opens.

Concretely:

1. **Per-chunk loop**: Mac + OrbStack only. The windowsmini gate
   is informational, not load-bearing.
2. **Phase boundary** (e.g. §9.9 close → §9.10 open): a new
   "Windows reconciliation" sub-step is mandatory before the
   phase widget flips. The sub-step:
   - Runs `bash scripts/run_remote_windows.sh test-all` once
     against the Phase's HEAD.
   - Categorises any FAIL into Win64-ABI / WASI / IPC-flake /
     other.
   - Files debt entries OR fixes inline depending on the
     category.
   - Records the green HEAD via `should_gate_windows.sh
     --record` so the next Phase starts from a known-green
     baseline.
3. **A13 release-tag gate stays unchanged**: pushes to `main`
   (release-tag-style) still require the full strict 3-host
   green per `scripts/gate_merge.sh`. That's a user-driven
   event, not autonomous-loop scope.
4. **`should_gate_windows.sh` becomes informational** (not
   gate-failing) inside the loop. The `gate-required` /
   `gate-deferred` output remains useful as a heuristic for
   the user (e.g. "show me how many windowsmini-affecting
   commits accumulated") but the autonomous loop ignores it.
5. **Memory + skill / rule updates**: this ADR is referenced
   from `.claude/skills/continue/LOOP.md` (Push policy / Test
   gate sections), the `feedback_windowsmini_gate.md` memory
   record, and CLAUDE.md "Mandatory pre-commit checks". All
   prior wording suggesting per-chunk windowsmini is updated
   to point to this ADR.

## Alternatives considered

### Alternative A — keep heuristic (`should_gate_windows.sh`) gating

- **Sketch**: leave the existing heuristic that runs windowsmini
  every 4-10 commits OR when ABI-touching paths change.
- **Why rejected**: the heuristic was designed to amortise the
  cost, but in practice still dominates wall-clock since most
  meaningful chunks touch generic IR / spec / corpus paths that
  legitimately benefit from windowsmini coverage in theory but
  rarely surface unique findings. The user's empirical assessment
  ("clearly a bottleneck") is the load-bearing rejection.

### Alternative B — drop windowsmini entirely

- **Sketch**: never run windowsmini, including at release tags;
  treat Windows x86_64 as a best-effort port with no gate.
- **Why rejected**: Win64 ABI + WASI fd-dispatch differences are
  real and have caught regressions before (e.g. v1's WASI carry-
  over diffs). Releases need confidence; A13 stays.

### Alternative C — run windowsmini only on tag

- **Sketch**: skip per-chunk AND per-phase, run only at release
  tag time.
- **Why rejected**: phase boundaries are months apart; release
  tags are quarters apart. Accumulating Windows debt across an
  entire release would surface a debugging cliff at tag time
  worse than the current treadmill. Phase-boundary cadence is
  the sweet spot — ~weekly/biweekly batch with enough delta to
  keep failures bounded.

## Consequences

- **Positive**: autonomous loop wall-clock per chunk drops
  significantly; Mac + OrbStack 2-host gate finishes in ~3 min
  vs ~15 min with windowsmini. Higher chunk throughput.
- **Positive**: phase-boundary "Windows reconciliation" debugging
  is concentrated, allowing batch tooling (e.g. parallel SSH
  test runs, lldb-on-Windows-via-ssh) and dedicated focus.
- **Negative**: Windows-specific regressions may go undetected
  for the duration of a Phase. Mitigated by `audit_scaffolding`
  at phase boundaries explicitly walking the Win-specific code
  paths + the new "Windows reconciliation" sub-step running
  before the next phase opens.
- **Negative**: A13 release-tag gate becomes the load-bearing
  Windows-coverage point. If a Phase reconciliation skipped a
  Windows failure that the release-tag gate then catches,
  diagnosis happens at tag time under release pressure. Risk
  mitigation: the Phase-boundary reconciliation MUST achieve
  full green; it's not optional housekeeping.
- **Neutral**: `should_gate_windows.sh` is not deleted — kept as
  an informational heuristic. Loop just stops gating on it.

## References

- ROADMAP §A13 (merge gate definition; this ADR scopes it to
  release-tag pushes only, NOT autonomous loop)
- `.claude/skills/continue/LOOP.md` (Test gate § will reference
  this ADR after the next chunk lands the wording change)
- CLAUDE.md "Mandatory pre-commit checks" (windowsmini line
  becomes deferred-batch reference)
- Memory: `feedback_windowsmini_gate.md`
- Related ADRs: ADR-0044 (Phase 9 row scope merge — bench-
  driven), ADR-0047 (scaffolding audit cadence)
- Initial discussion: 2026-05-11 between project owner + loop
  during §9.9 / 9.9-g-8 close cycle.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-11 | (filing)     | Initial accepted version.               |
| 2026-05-17 | `58e69207` | Linux x86_64 gate host pivoted from OrbStack `my-ubuntu-amd64` (Rosetta-translated, D-134 root cause) to native `ubuntunote.local` per ADR-0067. windowsmini Phase-boundary reconcile shape unchanged.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 2026-05-18 | `86fad986` | **Phase-boundary reconcile slot specified** — "Phase boundary" originally read ambiguously as "during §9.9 close (= sub-row 9.9-IV)". Per user 2026-05-18 confirmation, windowsmini reconcile runs at the **dedicated §9.13-0 row** (inserted between §9.12 substrate audit hard-gate and §9.13 Phase 10 entry hard-gate), NOT inside §9.9. Rationale: §9.12 substrate audit may amend Phase 9 scope retroactively (D-094/D-140 cohort dispositions); running windowsmini reconcile BEFORE the cleanup risks duplicate work. §9.9 close exit predicate applies to Mac + ubuntunote only; windowsmini bit-identical verification gated at §9.13-0. ADR-0056 Revision-history 2026-05-18 row pairs this. 3-host invariant preserved across the §9.9 → §9.12 → §9.13-0 → §9.13 chain — split across rows, not loosened. |
