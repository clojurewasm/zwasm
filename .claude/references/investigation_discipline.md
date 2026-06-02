# Investigation discipline — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/investigation_discipline.md`](../rules/investigation_discipline.md).


# Investigation discipline

When a bug requires multi-cycle investigation, two complementary
disciplines apply: **enumerate hypotheses with rejecting evidence**
(during the hunt) and **discharge with cause-named close OR
empirical streak** (when the hunt converges).

## §1 — Hypothesis enumeration (during multi-cycle hunt)

### When this applies

Any bug whose investigation spans **more than 1 cycle**. Single-
cycle bisects don't need this overhead; multi-cycle hunts do — the
case where "next investigator re-explores from scratch" is expensive.

Trigger ≈ `now` debt row that survived one resume without close.

### Procedure

When the bug is still open after the cycle ends, the debt row / handover
MUST carry an **enumerated hypothesis list** built in this order:

**Step 0 — Framing challenge** (BEFORE enumerating any hypothesis;
per lesson `2026-05-18-debt-dedup-grep-before-file.md`):

1. Grep `.dev/debt.yaml` for the affected source-file / function names
   + symptom keywords ("stale" / "off-by-one" / "wrong-register" etc.) —
   does a `now`-status row already document this bug class under
   different framing?
2. Grep `.dev/lessons/INDEX.md` for the same keywords — is there
   a prior investigation that already mapped this space?
3. If either grep hits → **dedup**: update the existing debt row /
   cite the existing lesson; don't open a fresh investigation. The
   inherited framing from the discovering chunk's narrative is often
   too narrow and hides class-overlap.

**Then for each genuinely-new hypothesis**:

1. Numbered hypothesis name (e.g., "(1) PAC", "(2) siglongjmp re-entry").
2. **Predicted observable signature** — what you'd see if true.
   Concrete: a register value, fault address pattern, stderr line,
   directory count.
3. **Distinguishing probe** — the cheapest single experiment that
   would confirm / reject it.

Rejected hypothesis: mark `~~rejected~~` with rejecting commit SHA but
**keep in the list**. Future cycles must not re-walk rejected paths.

New mid-investigation hypothesis: **append with next number** + same
shape (signature + probe). Don't insert in middle.

### Template (paste into debt row or lesson body)

```markdown
**Hypotheses** (numbered; rejected marked ~~strikethrough~~ with SHA):

1. ~~<name>~~ — REJECTED <SHA> via <probe>. <evidence summary>.
2. ~~<name>~~ — REJECTED <SHA> via <probe>. <evidence summary>.
3. <name> (active) — predicted signature: <what we'd see>.
   Distinguishing probe: <single experiment>.
4. <name> (NEW, from cycle N): ...

**Leading hypothesis** (if narrowed): <#N>. **Next probe**:
<concrete one-cycle experiment>.
```

### Where the list lives

- **Open + currently investigating**: debt row body. Handover
  references the row (`see D-NNN`); does not duplicate.
- **Closed (root cause identified)**: promote to lesson under
  `.dev/lessons/`. Preserve enumerated list as audit trail —
  re-derivability value depends on future investigators seeing WHY
  each branch failed.

### Why §1 exists

**D-142 (Mac aarch64 cross-module SEGV)**: 6 cycles to root-cause.
Cycles 1-5 each rejected one hypothesis via a targeted probe;
cycle 6 converged because the prior 5's rejection evidence was
recorded explicitly. Without the discipline, cycle 6 would have
re-walked PAC and siglongjmp branches.

## §2 — Heisenbug discharge (empirical streak when no root cause)

For layout-sensitive / non-deterministic flakes where direct
root-causing has failed, a discharge gate exists. D-134 (Mac aarch64
Rosetta) was the original case study — root-caused at 2026-05-17 as
Rosetta signal-translation race and **closed by ADR-0067 ubuntunote
pivot** (environmental fix), NOT empirical streak. The streak rule
below applies to future heisenbug rows.

### Discharge gate (all 4 must hold)

A heisenbug debt row may discharge when ALL hold:

1. **Streak**: ≥ **5 consecutive `silent` outcomes** (no reproduction)
   under the bug's original reporting conditions. "Silent" is defined
   per-bug in the row's `Discharge plan` § (e.g., exit code 0 from
   `bash scripts/run_remote_ubuntu.sh test-all`).
2. **Binary-layout diversity**: 5 silent runs span ≥ 3 distinct
   commit SHAs that structurally differ in the suspected root-cause
   code area. Same-compile-artifact streak is not evidence —
   heisenbugs are layout-sensitive by construction.
3. **Instrumentation in place**: if the row called for diagnostics
   (signal-handler probe, trace ringbuffer), it must still be in the
   binary. Otherwise the streak proves "this binary didn't repro",
   not "the fix held".
4. **No alternative explanation**: if the loop reduced reproduction
   via layout-perturbing changes (binary size, errdefer additions)
   without naming root cause → streak is **rate-reduction evidence,
   not root-cause-fix evidence**. Discharge requires either named
   root cause OR an ADR documenting rate-reduction as chosen
   mitigation.

### Outcome words (tracker convention)

- `silent` — bug did not manifest (evidence of fix-or-rate-reduction)
- `fail` — bug reproduced as original failure mode
- `segv` — SEGV-class failure; treated identically to `fail` for streak

Any non-`silent` outcome resets the streak counter to 0.

### Tracker invocation

```sh
# Record after each per-chunk gate run:
bash scripts/track_heisenbug.sh d134 silent  # OR fail / segv

# Inspect:
bash scripts/track_heisenbug.sh d134 --status
```

Logs land in `private/heisenbug-<name>.log` (gitignored). Per-machine
state; this rule is project-wide.

### Discharge procedure

When the streak fires (script prints `DISCHARGE CANDIDATE`):

1. Verify all 4 conditions manually (script counts only the streak).
2. Pair discharge commit with **either**:
   - Named root cause in commit body (e.g. "altstack expansion fixed
     the signal-mask race; see siginfo ring buffer at SHAs X/Y/Z"),
     OR
   - ADR documenting rate-reduction-as-mitigation strategy with
     residual-risk acknowledgement.
3. Delete debt row + tracker log (`--reset` archives it).
4. If a lesson exists for the heisenbug's failure mode, update its
   `Related` § to point at the discharge commit.

### What §2 rejects

- **"It hasn't reproduced this session, must be fixed"** — one
  silent run is not evidence. Heisenbugs reproduce as low as 1/30 runs.
- **"DISCHARGED" claim in handover without commit-side evidence**
  (d-68 lesson `narrative-claim-vs-landed-state.md`). Handover is
  fiction until git records the discharge.
- **Same-binary streak** — condition 2 rejects this.
- **Closing without naming cause OR documenting rate-reduction** —
  condition 4 rejects; silent closure-path failures = permanent
  latent risk.

### Why threshold = 5

- At observed D-134 rate (1/5 to 1/30 per d-67..d-81 evidence), 5
  silent runs ≈ 50-95% CI lower bound for "rate now near zero".
- 10 = more conclusive but adds wall-clock days.
- 3 = too short; D-134 observed 2-3 silent gaps followed by repro.

Configurable per-call via `--threshold N` (project default 5);
deviations require ADR-level justification.

## Reviewer checklist

For §1 (active investigation):

- [ ] Hypotheses numbered + named?
- [ ] Each rejected hypothesis cites rejecting SHA + probe?
- [ ] New hypothesis carries (a) predicted signature + (b) distinguishing probe?
- [ ] Active "leading hypothesis" names a SINGLE next probe?
- [ ] When investigation closes, list preserved in lesson?

For §2 (discharge attempt):

- [ ] 5+ silent outcomes recorded by `track_heisenbug.sh`?
- [ ] Spans ≥ 3 distinct SHAs with structural code variation?
- [ ] Instrumentation still in binary?
- [ ] Discharge commit body names root cause OR cites mitigation ADR?

## Stale-ness

- §1: if a multi-cycle debt row has no enumerated list, file
  `audit_scaffolding` finding (or fix inline mid-`/continue`).
- §2: if a heisenbug row carries the streak fields but
  `track_heisenbug.sh` log doesn't exist on the recording host,
  the streak is unauditable; restart counting from 0.

## Related

- ADR-0067 (ubuntunote pivot — environmental fix for D-134)
- `.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`
  (the D-134 investigation pattern — LD_PRELOAD shim, handler probe,
  vanilla C reproducer)
- `.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md` (d-68
  case — handover-claim vs landed-state divergence this rule defends)
- `.dev/lessons/2026-05-18-debt-dedup-grep-before-file.md` (Step 0
  framing-challenge motivation)
- [`handover_doc_discipline.md`](handover_doc_discipline.md) §2 —
  no future-tense numeric predictions (complement to §1 hypothesis
  list which IS allowed to enumerate predictions because each has
  a probe).
