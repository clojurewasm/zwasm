# Phase 10 "100% both backends" — scope reassessment (prep for full investigation)

> **Doc-state**: ACTIVE
>
> Light-investigation PREP only (per user directive 2026-06-02). The FULL
> investigation + the ADR-0128 amendment decision happen in a fresh session.
> This doc is the wiring / reference chain so that session starts fast and
> tackles it in one pass. It does NOT prescribe the resolution.

## The tension (one paragraph)

ADR-0128 defines the §10 exit as **pass=fail=skip=0 on BOTH backends**
(interp + JIT). But the JIT corpus has **~407 multi-memory `skip`s** that are
explicitly **Phase-14-deferred** (the JIT rejects >1 memory at compile:
`Error.MultipleMemories`). So **JIT `skip=0` is unreachable in Phase 10** —
the exit criterion as written can't be met until Phase 14 lands multi-memory
JIT. The honest in-phase target is likely *interp-100% + JIT-modulo-deferred-
multi-memory*, but changing the exit bar is an ADR-0128-scope decision (user-
gated; flagged by the user as worth a deliberate investigation).

## Reference chain (read these, in order)

1. **ADR-0128** `.dev/decisions/0128_phase10_100_percent_both_backends.md:37-39`
   — exit wording: "100% … pass=fail=skip=0, on BOTH the interpreter and the
   JIT." Status Accepted (user "100%" directive). **No deferred-skip caveat.**
   Also §2 already documents one deliberate deferral (GC-on-JIT rooting) — a
   precedent for documenting multi-memory deferral the same way.
2. **ROADMAP §10** `.dev/ROADMAP.md:1331` — "pass=fail=skip=0 (both backends)";
   six rows at 1353-1358; **10.P close** = `scripts/check_phase10_close_invariants.sh`
   (23 invariants, design plan §8). No multi-memory/Phase-14 caveat in §10 text.
3. **Multi-memory deferral** `src/engine/compile.zig:124` (`> 1 → Error.MultipleMemories`,
   memidx-fixed-at-0 MVP) + `src/parse/sections.zig` (enabled at parse, count>1
   enforced at runtime, "10.M-2") + `debt.yaml` ("multi-memory 51 = Phase-14
   deferred"). The deferral is real but lives in code/debt, NOT in ADR-0128/§10.
4. **JIT skip breakdown** `.dev/handover.md` "PER-MODULE blocker-STACK" + the §1
   runner. ~407 multi-memory skips (deferred); the **non-deferred** JIT skips
   (InvalidGlobalInitExpr 9, UnsupportedOp 7 any.convert_extern, StackTypeMismatch
   6 funcref br_on_null, UnsupportedEntrySignature 7, InvalidFuncIndex 4) ARE
   Phase-10-closeable — the full investigation should re-measure these fresh.
5. **§1 runner skip classification** `test/spec/spec_assert_runner_wasm_3_0.zig`
   — `jitErrorIsUnwiredShape(error.MultipleMemories)` → counted as skip. Decide
   whether multi-memory stays a "skip" or a "deferred-excluded" category.
6. **Amendment mechanism** ROADMAP §18 (`.dev/ROADMAP.md:1818-1900`; "regression
   allowance / phase order change" needs an ADR) + `phase10_transition_gate.md`.

## Remaining FAILS for fail=0 (the other half of the bar)

- **interp**: was 5; **`.17` "run" now CLOSED** (`80aeee1d` — call_indirect
  subtype + function-level br). Remaining interp = **4 assert_trap fail** (other
  gc/type-subtyping modules — NOT .17). The runner self-notes "assert_trap class
  discrimination land in follow-on cycles" (`spec_assert_runner_wasm_3_0.zig`
  total line) — these 4 may be a runner trap-class-matching limitation, not
  interp bugs. **Investigate which modules + whether runner-side.**
- **JIT**: gc/type-subtyping (same RTT, now likely also closeable via the .17
  fix on the JIT path — re-measure) + **eh/try_table** (EH-on-JIT, deep).

## Decision points for the next session (resolve in one pass)

1. **Amend ADR-0128?** Add a §Caveat/§Removal-condition excluding Phase-14-
   deferred multi-memory JIT skips from the §10 `skip=0` bar (mirroring §2's
   rooting-deferral precedent) — OR hold the bar and accept §10 cannot close
   until Phase 14. (ROADMAP §10 + 10.P invariant script must match the choice.)
2. **Reclassify multi-memory skips?** A distinct "deferred-excluded" tally in the
   §1 runner + `check_phase10_close_invariants.sh`, so `skip=0` means "0
   non-deferred skips". Where + how counted.
3. **Re-measure the non-deferred gap fresh** (skips #4 above + the 4 interp
   trap_fails + JIT eh/try_table) — what's genuinely Phase-10-closeable vs
   deferred. This sizes "how close is interp-100% / JIT-modulo-deferred".
4. **10.P close-invariant script** (`scripts/check_phase10_close_invariants.sh`,
   design plan §8) — does it need the carve-out, and is the design plan the SSOT
   for it?

## Status of the active bundle when this was written

`10.G-typesubtyping-RTT`: `.17` run CLOSED (`80aeee1d`+`24a17ed7`). The 4
gc/type-subtyping `assert_trap` fails + the §10-scope question are the open
items. PHASE C (cross-module type-def identity) closed the 4 assert_unlinkable
earlier in this bundle-chain.
