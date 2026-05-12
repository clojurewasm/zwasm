---
name: loop-defers-over-fixes-when-cost-high
description: Autonomous /continue loop chose defer / skip-ADR / debt-row over root-cause fix when investigation cost looked high (D-092 deferral + D-091's initial skip-ADR detour). Project tone is `no_workaround.md` "fix root causes" — even at high investment cost — so the loop's "pivot to cheaper chunk" instinct violates the rule.
metadata:
  type: feedback
---

# Loop tends to defer-with-debt-row when fix cost looks high

**Why**: Project P/A and `.claude/rules/no_workaround.md` are
explicit: "Fix root causes, never work around." "Missing
feature? Implement it first." "Defer rather than work around"
is allowed only with an ADR documenting the deferral as
load-bearing — not as a routine escape valve.

The autonomous /continue loop developed a habit during the
§9.9 / 9.9-l-1b expansion of treating "investigation cost
high" as a reason to pivot to a cheaper chunk, filing a debt
row in lieu of investigating. Two concrete violations on
2026-05-12:

1. **D-091 initial detour**. When the `i32.trunc_f64_s`
   boundary case surfaced as a Mac/OrbStack differential, the
   loop's first move was a regen-script `skip-adr-x86_64_trunc_precision`
   filter + new skip-ADR + debt row — workaround landed first,
   fix came as a follow-up chunk. The correct first move was
   to investigate the x86_64 emit immediately (the fix turned
   out to be a ~30-line diff in `op_convert.zig`).
2. **D-092 deferral**. When `f32.0.wasm` / `f64.0.wasm`
   compileWasm rejected on OrbStack with `UnsupportedOp`, the
   loop pivoted to D-091 (which it had also deferred). The
   `UnsupportedOp` came from a single specific op in an
   11-op module that the loop could have bisected in 10
   minutes; instead D-092 sat as a debt row blocking the
   f32/f64 corpora additions.

**How to apply**: On the next /continue resume:

- D-092 is the SOLE next-task, framed as a root-cause
  investigation. Walk `extended_challenge.md` Step 1
  (Confirm what's absent — `wasm-objdump -d` + targeted
  compileWasm trace per func[0..10]) before any fallback /
  filter motion.
- Generalised: when a chunk encounters a failure that looks
  like it'd need ≥ 30 min of investigation, the **default**
  is to spend that 30 min, not to defer. Defer is allowed
  ONLY when the investigation surfaces a structurally
  load-bearing barrier (e.g. blocked by Phase 10's reftype
  runtime work). "I don't want to read X right now" is not
  a structural barrier.
- The skip-ADR mechanism exists for genuine ADR-grade
  workarounds (e.g. upstream bug with named expiry), not as
  a routine smoothing path for the loop's own scheduling
  budget. If a chunk's first reach is for a skip-ADR before
  the fix, that is a rule violation.

**Citing**: `f22acf6c` (D-091 close — the eventual fix
landed 1 chunk after the workaround; should have been the
first chunk). D-092 row in `.dev/debt.md` (status `now`
post-this-lesson; investigation chunk pre-staged at next
resume).
