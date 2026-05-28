# D-180 detector: bounds_fixups-append is an implicit R15 user

> **Date**: 2026-05-28
> **Tags**: x86_64, JIT, usesRuntimePtr, R15, bounds_fixups, check_uses_runtime_ptr, D-180, drift detector, integration test, 10.R cycle 51
> **Citing**: `af477394` (10.R cycle 51b fix-forward)

## Observation

10.R cycle 50 (`86e5bfaf`) landed a new x86_64 per-op file
`ref_as_non_null.zig` that calls `ctx.bounds_fixups.append(...)`
(appending a JE rel32 fixup so the function-end trap stub at
`op_control.zig:1303-1325` patches it to the trap entry). The
pre-commit `check_uses_runtime_ptr.sh --gate` printed `OK — no drift
detected`. But ref.as_non_null was NOT in the `usesRuntimePtr`
whitelist, so the prologue did not PUSH-save R15, so the trap stub's
`MOV [R15 + trap_flag_off], 1` wrote to garbage at runtime, and
cycle-51's integration test (which exercised the trap path) caught
the silent miscompile on the very first ubuntu kick.

Why the detector missed it: the heuristic scans each op file for the
**lexical regex `[rR]15`** in non-comment code (per the script body
around line 60-80). My file doesn't mention R15 — it appends to
`bounds_fixups`, an implicit cross-file dependency: the **trap-stub
generator in `op_control.zig`** emits the R15 STR if and only if any
op appended to `bounds_fixups`. So the actual rule is:

> Any x86_64 op file that calls `bounds_fixups.append(...)`
> (or analogously `unreach_fixups.append`) **implicitly forces R15
> initialisation** via the function-end trap stub. The op MUST be
> whitelisted in the "trap-stub emitters" section of `usage.zig`
> (alongside `unreachable`, `i32.div_*`, `trunc_*` etc.).

The lexical-R15 heuristic catches direct R15 use but misses this
indirect channel.

## Why this lesson and not an amendment to the existing D-180 lesson

The existing 2026-05-28 lesson `x86_64-uses-runtime-ptr-eh-gap.md`
records the root-cause + structural defenses for the D-180 bug class.
This cycle-51 instance **applied that lesson** (the fix was a single
whitelist line) — it didn't change the root cause analysis. What this
lesson records is a complementary observation: the drift detector
that the original lesson cited as a structural defense has a known
heuristic gap that integration tests had to cover.

The implication: when 10.R's br_on_null / br_on_non_null land (also
appending to a fixup list, though `label_fixups` not `bounds_fixups`)
and any other future op that appends to a trap-stub-feeding list,
the author must remember the whitelist AND not rely solely on
`check_uses_runtime_ptr.sh` to remind them.

## Hardening opportunity (deferred — not blocking)

`check_uses_runtime_ptr.sh` could be extended: scan each per-op file
for `\.bounds_fixups\.append\|\.unreach_fixups\.append` and require
the op to be in the whitelist. That would catch this class
pre-commit instead of relying on the post-push integration test.
Filed under "next maintenance pass" — the loop's verify-revert
mechanism (Step 0.7 ubuntu read) is the working backstop today.

## Process win that's actually being recorded here

The whole reason D-193 (and its ungate stream cycles 41-47) existed
was to surface exactly this class of silent x86_64 miscompile. The
cycle-50 + cycle-51 sequence demonstrated the design working:

1. Cycle 50 landed buggy x86_64 emit (the pre-commit detector
   missed; Mac tests passed because Mac is immune).
2. Cycle 51 landed an end-to-end execution test — the test trapped
   correctly on Mac but returned 0 on ubuntu.
3. Ubuntu's `[run_remote_ubuntu] FAIL` triggered investigation.
4. Cycle 51b's fix-forward (`af477394`) patched the whitelist in
   under 10 minutes from FAIL signal to green re-kick.

The discipline that pays off: a real execution test per emit op
(spike_discipline §2's "behavior observable point") + ubuntu kick
per cycle (ADR-0076 D3) + Step 0.7 verify-on-resume. Without ALL
three, the bug stays latent.

## Related

- `.dev/lessons/2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`
  (original D-180 root-cause lesson)
- `scripts/check_uses_runtime_ptr.sh` (the detector with the gap)
- `src/engine/codegen/x86_64/usage.zig` (the whitelist)
- `src/engine/codegen/x86_64/op_control.zig:1303-1325` (trap stub
  generator that's the implicit R15 user)
- ADR-0122 D6 + D-193 ungate stream — the design rationale for
  having tests like cycle 51's that catch this class
