# 0186 — Completion-grade gap-area reframe of ROADMAP §9 + drift reconciliation

- **Status**: Accepted 2026-06-15
- **Author**: claude (user-directed — "ほぼ完成しきっているこの段階で再整理＋取り組み内容の再配線", modelled on ClojureWasm's ADR-0142 reframe)
- **Supersedes/amends**: ROADMAP §9 framing (forward phase-queue → completion-grade), §2 P2 + P14 example, §3.1 heading, §9 "Post-completion (v0.2.0 line)" stub. Composes with ADR-0156 (no autonomous release), ADR-0181 (version lines retired), ADR-0159 (CLI = run+compile).

## Context

zwasm v2 has reached the **完成形 plateau**: Phases 0–16 are DONE, the
Phase-status widget already carries **Phase 17 = "Feature line / completion-
refinement"** (IN-PROGRESS), 3-host green, debt healthy (47 rows, 0 `now`),
and the surface-audit sweep (diag/CLI/C-API/Zig-API/docs) + a ground-truth
debt sweep both came back clean this session.

But ROADMAP §9 still **reads as a linear forward phase-queue** whose section
bodies stop at Phase 16 + a 4-line **"Post-completion (v0.2.0 line)"** stub —
a framing that (a) no longer matches the plateau, and (b) contradicts
already-landed decisions. Concrete drift found (the symptom the user named —
"最初に敷いたROADMAPは時がたち、乖離もしていれば、debtや未実装の将来先送り要因にもなりかねない"):

1. **§2 P2** lists the single binary serving `run / compile / validate /
   inspect / features / wat / wasm` — but ADR-0159 (§16.4) removed
   validate/inspect/features/wat/wasm; the CLI is `run` + `compile` only.
2. **§3.1** heading "In scope (will be implemented for v0.1.0)" keeps a
   version gate that ADR-0181 (+ ADR-0156) retired.
3. **§2 P14** + §15 frame Phase 15 as "port v1's W43/W44/W45 optimisation
   work"; §15 actually MEASURED those as ~0-headroom and instead closed the
   D-265 register-homing rework (ADR-0153). The example is stale.
4. **"Post-completion (v0.2.0 line)"** duplicates/contradicts §1.3 (capability
   backlog, no version lines) and §3.3 (deferred, demand-driven).

ClojureWasm hit the same near-completion inflection and resolved it with
**ADR-0142** (a "completion-grade gap-area model": retire the forward
phase-queue, reframe remaining work as a few live fronts + a genuinely-future
bucket, keep phase numbers as stable anchors, re-barrier debt to the new
terms). We adopt the same shape for zwasm.

## Decision

1. **§9 gains a "§9.0 Completion-grade model"** subsection: the project is at
   the 完成形 plateau; Phases 0–16 DONE + Phase 17 = steady-state feature/
   refinement line; remaining work = a small set of **live fronts** + a
   **genuinely-future bucket** (no version queue). Old Phase numbers stay as
   **stable section anchors** for existing citations; the front is the real
   unit. The goal-line is the **完成形 bar** (§1.2), a named state — never a
   version (release is user-only, ADR-0156).

   **Live fronts** (honest, post-sweep):
   - **Front A — surface/diagnostic finishing tail**: D-334 validator-diag
     (cap-bounded stop, principled), F6 per-section parse diags (ADR-grade),
     F4 trap-format (user-gated). Effectively drained → monitoring.
   - **Front B — debt natural-discharge / steady-state hardening**: the
     external-blocked (upstream Zig / hosts) + future-phase rows, re-evaluated
     every `/continue` Step 0.5 as their barriers dissolve.
   - **Front C — dogfooding-driven**: the cw-v1 `@import("zwasm")` consumer
     (D-264) when it lands.

   **Genuinely-future bucket** (demand-driven, no version gate — the §1.3 +
   §3.3 set): threaded EXECUTION, stack-switching / WASI 0.3, RISC-V / s390x
   backends. The optimising tier is **permanently out** (single-pass, §3.2).
   The old "v0.2.0 line" items reconcile: Component Model + WASI 0.2 already
   SHIPPED → §1.2 floor; threads+atomics → threaded-EXECUTION future; tier
   promotions → demand-driven.

2. **Reconcile the 4 drift sites in place** (four-step amendment, this ADR):
   P2 → `run` + `compile`; §3.1 heading → version-gate removed; P14 example →
   "Phase 15 measured the v1 ports ~0-headroom and closed the D-265 register-
   homing rework instead"; "Post-completion (v0.2.0 line)" stub → replaced by a
   pointer to §9.0's future bucket + §1.3.

3. **Debt re-placement** (separate commit, same campaign): group the ledger by
   front (live / future-bucket / external-blocked / user-gated), mirroring
   ClojureWasm's D-440 re-barrier. No new `F-`/`O-` prefixes (user-chosen):
   §1.2/§2/§14 already serve as the project-facts anchor and §1.3/§3.3 as the
   future bucket — consolidate into them rather than add a letter series.

4. **ADR hygiene** (same campaign): verify superseded/closed ADR statuses are
   marked (e.g. ADR-0025 → 0109).

## Consequences

- §9 stops reading as "march toward the next phase"; it reads as "plateau +
  demand-driven fronts," matching ADR-0156/0181 and the actual loop posture.
- Existing "Phase N" / §9.N citations still resolve (anchors preserved).
- The loop's next-task selection is driven by the front list + Step 0.5 debt
  sweep, not by an exhausted phase queue.
- No behaviour/code change — this is a planning-doc + debt-ledger reconciliation.

## Alternatives considered

- **Capability-matrix successor** (drop phase numbers entirely, à la
  ClojureWasm's D-443): heavier; deferred. The gap-area redirect is the
  lighter, sufficient step now.
- **Introduce `F-`/`O-` prefixes** to match ClojureWasm vocabulary: rejected
  by the user in favour of consolidating into existing §1.2/§2/§14/§1.3/§3.3.

## Revision history

- 2026-06-15 — created (user-directed near-completion ROADMAP re-organization).
