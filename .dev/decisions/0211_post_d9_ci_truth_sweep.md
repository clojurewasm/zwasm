# ADR-0211: post-D9 CI truth sweep — retire nightly.yml, add bench-watch, make the Windows leg blocking (discussion #201)

> **Doc-state**: ACTIVE

- **Status**: Accepted (2026-08-19 — maintainer decision on discussion #201)
- **Date**: 2026-08-19
- **Front**: B-hardening (CI/gate truthfulness)
- **Findings base**: discussion #201 (2026-08-18) plus a re-verification of
  `origin/main` on 2026-08-19. Empirical numbers cited below carry their own
  dates and are not re-derived by any gate.

## Context

ADR-0076 D9 (2026-07-03) made CI's `ci-required` the authoritative merge gate
and demoted local gating to an optional pre-flight. Three arrangements built on
the older *local-first, CI-second-line* premise (2026-05-25) were never
re-decided afterwards; discussion #201 surfaced them, and the maintainer ruled
none of the three was deliberate in its current form:

1. `.github/workflows/nightly.yml` was authored dispatch-only (2026-06-04,
   `17e3b6f1a`) citing the CI-second-line convention — which stopped being true
   when `ci.yml` regained auto triggers (2026-07-01, `24b1de61a`). Its legs
   never ran on a schedule in this tree, and the workflow rotted around them:
   spec-bump exits 1 today (`.dev/spec_pin.yaml` is 66 days behind both
   upstream HEADs, and the check compares against a moving HEAD), the fuzz leg
   predates `fuzz_exec` (2026-06-20) and `test-aot-diff` so its §14.3 coverage
   claim is stale, there is no `zig-pkg` dep cache (one zlinter fetch flake
   kills the job), and tool versions are hardcoded instead of sourced from
   `.github/versions.lock` (bit once already, `4bdf0dd2b`).
2. The per-merge bench-record convention (`bench/README.md`, ROADMAP §14.2)
   assumed merges were local events. It has been dead in practice since
   2026-07-09 (the last `history.yaml` row): every merge since 2026-08-01,
   the `src/`-touching ones included, produced zero
   `bench/results/history.yaml` entries.
3. `ci.yml`'s `x86_64-windows` leg is `advisory: true` (2026-07-01,
   `1e21caa0c`), citing D-245 hosted-runner flakiness. D-245 was a zwasm bug
   (JIT prologue clobbered callee-saved registers on host entry; ADR-0144
   records the NATIVE host flaking from it — it was never a hosted-runner
   property), fixed 2026-06-04 (`510ffce9`), re-audited RESOLVED 2026-06-13
   (`c39e914f4`), and deleted from the ledger 2026-06-14. The flag postdates
   the fix by 27 days — and the ledger deletion by 17 — citing a row that no
   longer existed. Empirically the
   leg is stable: the 26 most recent gate-matrix runs (2026-08-15..18) were
   26/26 green on windows.

## Decision

### D1 — Retire `nightly.yml`; rebuild fresh when fuzzing becomes a focus

The workflow is deleted, not repaired: every leg needs redesign (spec-bump's
HEAD-relative gating is a treadmill that re-reds after every pin bump; the
fuzz leg misses the differential campaigns; the setup diverged from `ci.yml`),
so "fix in place" is a rewrite wearing an uncomment.

The revival hints move to debt row **D-593** (note): run `fuzz_exec` +
`test-aot-diff` campaigns rather than the loader fuzz alone; converge on
`.github/versions.lock` + the `zig-pkg` cache; decide spec-bump's gate-vs-warn
semantics; give a scheduled red a notification route (see D2's mechanism).

Named side-effects: `check_proposal_watch.sh` and `check_spec_bump.sh` lose
their only automation and become on-demand tools (both are manual-cadence
checks; `.dev/proposal_watch.md` was last reviewed by hand 2026-08-10). The
`spec_pin.yaml` staleness itself is standing maintenance work independent of
this ADR (runbook: `.dev/spec_revendor_runbook.md`).

### D2 — Per-merge bench convention retired; `bench-watch.yml` replaces it

ROADMAP §14.2's per-merge recorder convention is retired. `bench.yml`
(workflow_dispatch, curated `history.yaml`) stays for deliberate recordings.

What remains wanted is exactly one thing: **notice a gross regression with no
human in the loop and no commits out of CI**. A new scheduled workflow
(`.github/workflows/bench-watch.yml`, nightly, macos-15 + ubuntu-22.04 —
the two timing hosts per ADR-0137) runs `scripts/bench_watch.sh`:

- **Same-run A/B, not history comparison.** Build HEAD and the latest `v*`
  release tag in the same job; run the 5-fixture watch subset (the
  `run_bench.sh` windows-subset list — small, <30ms fixtures) on both,
  back-to-back, on the same runner, one hyperfine invocation per fixture
  comparing the two binaries. Machine identity and thermal state cancel;
  there is no baseline to persist, fetch, or trust. The baseline resets at
  each release tag by construction.
- **Threshold ≥2.0x slower on ≥2 fixtures.** Recorded same-host noise is ~7%
  with 2x+ first-run outliers (ADR-0209, `latency_history.yaml` header), so
  a 5%-class threshold is the mute-inviting gate ADR-0209 D3 rejected. This
  is a sky-is-falling detector by design. Measured while building it
  (2026-08-19, aarch64-darwin, HEAD `e1e6925ab` vs v2.5.0): without
  hyperfine `-N`, shell-startup calibration alone produced a phantom 5.0x on
  one sub-5ms fixture; with `-N` and 5 runs / 2 warmups every ratio sat in
  0.92–1.04x. `-N` is therefore load-bearing in `bench_watch.sh`, not a
  nicety.
- **Notification is GitHub-native, zero commits.** The script writes the
  comparison table to `$GITHUB_STEP_SUMMARY`, emits a `::warning::` per
  breaching fixture, and exits 1 on breach; a failed scheduled run emails the
  user who last modified the cron line (GitHub-documented behavior). Nothing
  is appended to `bench/results/history.yaml`, which stays curated and
  local-host-only — under its arch-only labels, hosted-runner rows would be
  indistinguishable from the maintainer-host rows.
- **It gates nothing.** Not wired to PRs; `ci-required` untouched; ROADMAP
  §12.1 ("A regression in any bench triggers investigation, not an automatic
  block") holds verbatim. The exit-1 is a notification channel, not a merge
  gate — no PR is associated with a scheduled run.

Alternatives rejected:

- **Threshold gate in `ci-required`** — rejected by ADR-0209 D3 and §14's
  forbidden list (numeric perf ratios in a CI gate); a noise-triggered gate
  gets muted, and a muted gate reads as coverage.
- **Compare against the previous scheduled run's artifact** — hosted runners
  differ in CPU model between runs, so cross-run ratios measure the fleet,
  not the code; it also adds artifact-fetch plumbing and a trust problem the
  same-run A/B simply does not have.
- **Reuse the `history.yaml` plumbing** (`--phase-record` + delta scripts) —
  couples the watcher to the curated-history schema and its append-only
  discipline for no gain; hyperfine's own `--export-json` already carries the
  two means being compared.

### D3 — The Windows leg becomes blocking

`advisory: true` is dropped; `x86_64-windows` joins mac/linux as a blocking
leg of `ci-required`. It is already the slowest leg (~13 min median vs ~7 for
Linux over the same 2026-08-15..18 sample), so the critical path barely moves. The `ci.yml` header rewrite removes
the D-245 sentence, and the authority contradiction the flag sat on is
resolved the way ADR-0076 D9 already decided: `docs/development.md`'s "CI is
the authoritative gate" is the true statement; the native win64 host remains
an optional pre-flight. Scope honesty, unchanged by the flip: a green windows
leg still skips the `.win64`-keyed test sites (~140, tracked by
`check_skip_helpers.sh`) and runs no extended checks (windows stays core-only).

If hosted-runner flakiness ever recurs, the answer is a debt row with the
measured signature and a revert of this one line — not a silent advisory flag
citing a closed bug.

## Consequences

- `ci-required` becomes a true 3-OS statement; a windows regression blocks the
  merge instead of scrolling past as a green check with a red sub-line.
- Gross (2x-class) performance regressions on either timing arch surface
  within a day, with zero effect on merge latency and zero bot commits.
- The fuzz/proposal/spec-bump automation gap is now explicit (D-593) instead
  of hidden behind a workflow that looked scheduled and was not.
- ROADMAP §14.2/§14.3 rows and the §14 exit criterion carry revision notes
  pointing here; the historical [x] records stay as records.
