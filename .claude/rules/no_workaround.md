---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# No-workaround rule

Auto-loaded when editing Zig source. Codifies a v1 lesson that
drove this redesign.

## Three principles (from ROADMAP §P4 / §P14)

1. **Fix root causes, never work around.** Missing feature?
   Implement it first. Spec gap? File a ROADMAP §9.<N+1> task; do
   not paper over.
2. **Spec fidelity over expedience.** Never simplify the API or the
   IR to avoid a gap. The Wasm spec is ground truth (P1).
3. **Defer rather than work around.** If a feature is genuinely not
   ready for the current phase, place it in a later phase and add
   a `// TODO(p<N>): <one line>` comment with the phase number.
   Never embed an indefinite workaround.

## Anti-patterns observed in v1 (to avoid in v2)

- **D116 abandoned address-mode folding**: tried, found
  ineffective, shipped anyway behind a flag, then reverted. The
  lesson: spike-then-measure is fine, but abandoned spikes belong
  in an ADR with `Status: Rejected`, not in the codebase.
- **W54 post-hoc liveness**: liveness was added late, broke x86
  because the regalloc-stage IR shape implicitly assumed an absent
  invariant. In v2: liveness is a `?Liveness` slot in `ZirFunc`
  from day 1 (ROADMAP §4.2 / P13).
- **D117 dual-entry self-call workaround**: introduced because
  inst_ptr cache + callee-saved competition couldn't be expressed
  cleanly. In v2: explicit `RegClass.inst_ptr_special` slot in
  `src/jit/reg_class.zig` from Phase 6.

## When spike work is OK

A spike is a learning experiment, not a delivery. Boundaries:

- ≤ 1 day of effort.
- Lives on a separate branch or a `private/spikes/` directory
  (gitignored).
- Outcome → ADR (Accepted with a follow-up ROADMAP entry, OR
  Rejected with the lessons captured).
- **Never** lands as a flag-gated workaround on `zwasm-from-scratch`.

## When a workaround is genuinely needed

Sometimes the upstream is broken (Zig 0.16 stdlib bug, OS quirk).
The bar:

1. ADR documents the workaround with: upstream issue link,
   expected expiry condition, removal plan.
2. Workaround is contained in one file (preferably `src/platform/`
   for OS quirks, `src/util/` for stdlib gaps).
3. A `// TODO(adr-NNNN): remove once <condition>` comment marks it.
4. `audit_scaffolding`'s "lies" check periodically verifies the
   removal condition still hasn't fired.

## Forbidden phrases in commit messages

- `quick fix` — escalate to root cause or ADR-document the
  limitation.
- `temporarily skip` — spec test skip=0 is a release gate (A10).
- `disable for now` — disable forever or fix; avoid the third
  option.
- `workaround for <upstream>` without an ADR reference.

## Reviewer checklist (apply during Step 4 Refactor / pre-commit)

- [ ] Does this fix the actual cause, or paper over the symptom?
- [ ] Is there an ADR for any non-obvious choice?
- [ ] Are abandoned alternatives noted (in ADR Alternatives section)?
- [ ] Will this still make sense in 6 months? (If not, what
      condition makes it expire?)
