---
paths:
  - ".dev/debt.md"
  - ".dev/lessons/**"
  - "scripts/track_heisenbug.sh"
---

# Heisenbug discharge — empirical-streak rule

Auto-loaded when editing `.dev/debt.md` or `.dev/lessons/`.
Codifies the closing procedure for layout-sensitive / non-
deterministic flakes (D-134 OrbStack `zwasm-spec-wasm-2-0-assert`
SEGV being the canonical case at filing time). Pairs with
`scripts/track_heisenbug.sh` for state and
`.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md` for
the failure-mode this rule exists to prevent.

## The rule

A heisenbug debt row may be **discharged** when ALL hold:

1. **Streak**: ≥ **5 consecutive `silent` outcomes** (no
   reproduction of the original symptom) under the conditions the
   bug was originally reported under. "Silent" is defined per-bug
   in the debt row's `Discharge plan` § — e.g. for D-134, exit
   code 0 from `zig build test-spec-wasm-2.0-assert` on OrbStack.
2. **Diversity of binary layouts**: the 5 silent runs must span
   ≥ 3 distinct commit SHAs that **structurally differ** in code
   touched by the heisenbug's suspected root cause area. A run of
   5 silent OrbStack passes from the same compile artifact is not
   evidence of fix — heisenbugs are by construction
   layout-sensitive.
3. **Instrumentation in place at the time of streak**: if the
   debt row called for instrumentation (signal-handler diagnostics,
   trace ringbuffer, etc.), that instrumentation must still be
   present in the binary. Otherwise the streak proves only "this
   binary didn't reproduce", not "the fix held".
4. **No alternative explanation**: if the loop has reduced the
   reproduction rate via known layout-perturbing changes (binary
   size, errdefer additions, etc.) without identifying a root
   cause, the streak is **rate-reduction evidence**, not
   root-cause-fix evidence. Discharge requires the root cause to
   be named in the close commit (or paired with an ADR
   documenting the rate-reduction as the chosen mitigation).

## What `silent` vs `fail` / `segv` mean

The debt row's `Discharge plan` § enumerates the exact
predicate. Tracker invocations from CI / the `/continue` loop
should encode this as a single outcome word:

- `silent` — the bug did not manifest. Encodes "this run is
  evidence of fix-or-rate-reduction".
- `fail` — the bug reproduced as the original failure mode.
- `segv` — for SEGV-class bugs, this is just a more specific
  failure name. Treated identically to `fail` for streak purposes.

Any non-`silent` outcome resets the streak counter to 0.

## Tracker invocation

After each per-chunk gate run that exercises the heisenbug-prone
test:

```sh
# Record outcome (autonomous /continue loop or CI hook).
bash scripts/track_heisenbug.sh d134 silent  # OR fail / segv
```

Inspect:

```sh
bash scripts/track_heisenbug.sh d134 --status
```

The script appends to `private/heisenbug-d134.log` (gitignored
per `.gitignore`). State is per-machine; the project-wide rule is
this document. CI on a different host maintains its own log.

## Discharge procedure

When the streak fires (script prints `DISCHARGE CANDIDATE`):

1. Verify all 4 conditions above (manual review; the script only
   counts the streak number).
2. Pair the discharge commit with **either**:
   - A named root cause in the commit body (e.g. "the d-72
     altstack expansion fixed the signal-mask race; see siginfo
     ring buffer evidence at commits X / Y / Z"), **or**
   - An ADR documenting the rate-reduction-as-mitigation strategy
     and the residual-risk acknowledgement.
3. Delete the debt row + delete the tracker log
   (`scripts/track_heisenbug.sh <name> --reset` archives it).
4. If a lesson exists for the heisenbug's failure-mode (e.g.
   `narrative-claim-vs-landed-state.md`), update its **Related**
   section to point at the discharge commit.

## What this rule rejects

- **"It hasn't reproduced in this session, must be fixed"** — one
  silent run is not evidence. The threshold exists because
  heisenbugs reproduce at rates as low as 1 / 30 runs (D-134
  observed rate per d-68/d-69).
- **"DISCHARGED" claim in handover narrative without commit-side
  evidence** — the d-68 case study (lesson
  `narrative-claim-vs-landed-state.md`). Handover narrative is
  fiction until git records the discharge commit + tracker log
  shows the streak.
- **Re-using the same binary across the streak** — condition 2
  rejects this; binary layout variation is the heisenbug's
  defining axis.
- **Closing without naming the cause OR documenting rate-
  reduction** — condition 4 rejects this; silent failures of the
  closure path are how heisenbugs become permanent latent risk.

## Why 5 (and not 3 or 10)

5 is a balance:
- At observed D-134 reproduction rate (~1 / 5 to 1 / 30 runs per
  d-67..d-81 evidence), 5 silent runs is roughly the 50-95% CI
  lower bound for "the rate is now near zero".
- 10 would be more conclusive but adds days of wall-clock to any
  discharge decision.
- 3 is too short — the D-134 case observed gaps of 2-3 silent
  runs followed by reproduction multiple times.

The threshold is configurable per-call via `--threshold N` but
the project default is 5; deviations require an ADR-level
justification (e.g. for a heisenbug with measured 1/100 rate, 10
might be warranted).
