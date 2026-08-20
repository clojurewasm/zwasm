# Phase 9 remaining work — flow reference

> **Doc-state**: ARCHIVED-IN-PLACE 2026-05-25 — Phase 9 = DONE
> 2026-05-24 (§9.13 hard gate cleared `36c494a3`; widget 9→DONE
> at 10.C9-step5); Phase 10 open. Drafted 2026-05-24 cycle 37
> post-ADR-0110 Accept. Body text stays as snapshot of the
> cycle-37 flow; for current work see ROADMAP §10 + handover.
> Don't edit body; cite-only.
>
> **Superseded-portion-by ADR-0109 (Accepted 2026-05-25)**:
> §3.3 / Phase F section references "F.2 ADR-0109 Accept → D-075
> native Zig API rewrite" as a deferred Phase F sub-step — that
> deferral is now resolved. ADR-0109 is Accepted; ROADMAP §10 /
> 10.J is the impl carrier (J.0 amend round complete; J.invest
> + J.1+ scheduled). D-075 re-scoped from "blocked-by Accept" to
> impl tracker.
> **Audience**: zwasm v2 maintainers + future-self cold-start
> entry. Sister doc to
> [`phase9_close_master.md`](./phase9_close_master.md) — the
> master plan covers the §5.3a 2-stage iteration discipline
> + invariant gate mechanism; this doc gives the high-level
> sequence-of-Phases view for "what happens between now and
> Phase 10 open" at a glance.

## §1 — Purpose

After Phase 9 真スコープ was expanded by ADR-0104 (Revision
2026-05-23) + ADR-0110 (cycle 37 Accept), the remaining
Phase 9 close work splits into 5 named Phases (A through E),
followed by Phase 10 open as Phase F. This doc is the
single-page sequence reference — what runs when, what's
autonomous vs user-gated, what runs in parallel, what the
"tests stay green" invariant looks like in practice.

This doc does **not** replace
[`phase9_close_master.md`](./phase9_close_master.md) §5.3a
+ §6 (the canonical iteration discipline + exit predicate)
nor [`.dev/phase9_value_widen_plan.md`](./phase9_value_widen_plan.md)
(the §9.13-V implementation playbook). It complements them
with a high-level visual.

## §2 — Full flow

```
NOW (cycle 37 closed)
  │  Mac+ubuntu test-all green
  │  windowsmini: D-167 11 directive fails
  │  Phase 9 close invariants: 18/18 PASS
  ▼

━━━ Phase A — §9.13-V Value=16 widen (autonomous, 9-12 cycles) ━━━

  A.1  scope audit                              (1 cycle)
       → private/spikes/value-widen-scope-audit/REPORT.md
       → honest re-count of the ADR-0052 "50+ test sites" claim

  A.2  test coverage strengthening              (2-3 cycles)
       → test/edge_cases/p9/value_semantics/
       → test/edge_cases/p9/v128_lane_ops/
       → test/edge_cases/p9/v128_nan_payload/
       → test/edge_cases/p9/v128_cross_instance/
       → all fixtures green at Value=8 baseline
       → CONTRACT: these same fixtures must stay green
         after Value=16 flip = behavior-preservation gate

  A.3  Value definition flip                    (1 cycle)
       → feature branch: zwasm-from-scratch-value16
       → src/runtime/value.zig: @sizeOf(Value) 8 → 16
       → main branch stays stable (parallel work runs there)

  A.4  cascade impl                             (3-5 cycles)
       ├─ a: storage layouts (operand_buf, globals_storage)
       ├─ b: JIT codegen globals (idx*8 → idx*16, Q-reg/MOVUPS)
       ├─ c: regalloc spill stride doubling
       ├─ d: JitRuntime extern struct field offsets recompute
       ├─ e: ZIR payload encoding 16-byte slot
       ├─ f: host_call marshal + c_api Val simplification
       │     + ADR-0109 facade Value section (no separate V128)
       ├─ g: spec runner GlobalsCtx removal
       └─ ★ D-167 wire-up folded in: entry.zig Win64 if-arms
              + wrapper bytes Value=16 stride update

  A.5  cope code removal verify                 (1 cycle)
       → grep 0 hits for: globals_offsets, globals_byte_storage,
         GlobalsCtx
       → net code delta ~-300..-500 LOC (cope removed)
       →              ~+50..+100 LOC (widened cleanup)
       → bottom line: net negative

  A.6  3-host verify + main merge                (1 cycle)
       → Mac + ubuntu + windowsmini test-all green
       → 11 D-167 directive fails cleared (byproduct)
       → D-079 (ii) discharged (byproduct)
       → feature branch rebase + merge to main
       → bench delta captured per Phase 8b discipline

  ────────── §9.13-V [x] ──────────


━━━ Phase B — §9.13-0 windowsmini reconcile (autonomous, 3-5 cycles) ━━━

  Independent of Phase A scope. Can run in parallel via
  cycle interleaving, OR sequentially after Phase A merge
  (cleaner windowsmini state).

  B.1  D-136 Win64 SEH bridge for assert_trap   (2-3 cycles)
       → C/asm shim sidecar to Zig runtime

  B.2  D-028 IPC flake CONFIRMED #5 final verify (1-2 cycles)
       → N=4 more silent runs (post-Windows-Defender fix)

  B.3  D-139 c_api Instance audit + coverage    (1 cycle)
       → instance lifecycle / zombie list / arena ownership tests

  ────────── §9.13-0 [x] ──────────


━━━ Phase C — §9.12-I ADR / lesson closure (autonomous, 1-2 cycles) ━━━

  Runs after Phase A + B SHAs are settled.

  C.1  ADR Status canonical pass
       → ~22-25 Phase 9 cohort ADRs:
         Accepted → Closed (Phase 9 DONE)
  C.2  Lesson Citing backfill
  C.3  check_adr_history.sh --gate = 0 verify

  ────────── §9.12-I [x] ──────────


━━━ Phase D — §9.12-F debt cohort dissolution verify (autonomous, 1 cycle) ━━━

  D.1  D-094 / D-062 / D-141 / D-081 / D-055 row state confirm
       → most dissolved by ADR-0106 / Q3 C adoption /
         per-op file pattern already
       → per ADR-0102 per-row predicate (a)(b)(c)(d) pass

  ────────── §9.12-F [x] ──────────


━━━ Phase E — §9.13 hard gate (USER collab review) ★ ━━━

  Autonomous loop STOPS here per the registered hard-gate
  rule (Resume Procedure Step 2 / Step 7 re-target
  detection). User resumes by walking the collab checklist.

  E.1  bash scripts/check_phase9_close_invariants.sh --gate
       → exit 0 expected (all I1-I7 hold)
  E.2  3-host test-all final green confirmation
  E.3  ADR-0105 + ADR-0106 Status confirm (already Accepted)
       + ADR-0110 implementation complete (Phase A done)
  E.4  Phase B re-flip with cited SHAs:
       §9.13-0 [x] + §9.12-F [x] + §9.12-I [x] +
       §9.13-V [x] + §9.13 [x]
  E.5  Track D collab final review
       (ADR-0104 真スコープ satisfied check)
  E.6  Phase Status widget: 9 IN-PROGRESS → DONE flip

  ────────── §9.13 [x] + Phase 9 DONE ──────────


━━━ Phase F — Phase 10 open (autonomous resume) ━━━

  F.1  §9.10 row inline expand
       → GC / EH / Tail call / multi-memory / memory64
  F.2  ADR-0109 Accept → D-075 native Zig API rewrite
       → ~6-8 cycles; can run in parallel with Phase 10
         feature work
```

## §3 — Tests stay green — what this invariant actually means

User direction 2026-05-24: "テストは通し続ける". Concretely:

- **Per-chunk gate** (existing /continue discipline): Mac +
  ubuntu test-all green per commit. No regression-then-fix-
  later. If a test fails mid-cycle, the chunk reverts before
  the next chunk.
- **Phase A.2 first** (test coverage): the Value semantics
  boundary fixtures are landed BEFORE the Value definition
  flip (A.3). This means the test gate is **strengthened
  before being stress-tested**. The fixtures form the
  behavior-preservation contract for A.4 cascade.
- **Phase A.3-A.5 on feature branch**: main stays stable
  for D-167 single-issue clearance (if needed) + Phase B
  parallel work. Feature branch's intentional breakage
  during cascade is contained.
- **Phase A.6 merge gate**: feature branch can't merge to
  main without 3-host test-all green + bench delta within
  tolerance.
- **Phase B / C / D**: each chunk gate honors normal
  /continue discipline.
- **Phase E (gate)**: 3-host test-all + invariant 18/18 +
  bench delta within tolerance + skip-impl ratchet 0 are
  ALL prerequisites for collab review entry.

The user's "テストは通し続ける" is therefore not a discrete
phase but an **invariant maintained across all Phases**,
with Phase A.2 as the explicit upfront investment that
makes the contract enforceable.

## §4 — Parallelization opportunities

| Pair | Independent? | Suggested interleaving |
|---|---|---|
| A ↔ B | ✓ scope-independent | A.1-A.5 on feature branch, B in chunks on main while A is in feature-branch land. A.6 merge waits for main green (B chunks completing helps). |
| A ↔ C | ✗ C needs A SHAs | C runs after A merge. |
| A ↔ D | ✓ technically | D is 1 cycle; defer to post-A for simplicity. |
| B ↔ C | ✗ C may need B SHAs | C runs after B. |
| B ↔ D | ✓ | Defer D to post-B / post-A. |

Cleanest sequencing:
```
A.1 → A.2 (1-2 chunk) → B.1 in parallel
A.3 → A.4 (feature branch) — long span; B.2 / B.3 run on main
A.5 → A.6 merge — main + feature reconciled
C → D
E (user)
F
```

Most aggressive sequencing:
```
A.1 / B.3 parallel
A.2 / B.2 parallel
A.3-A.6 feature branch / B.1 main parallel
C / D
E
F
```

Pace tolerance: at ~1 cycle / 30-60 min autonomous, the
sequence is **15-21 autonomous cycles + 1 user collab
session**, i.e. **1-3 calendar weeks autonomous + 1
user collab cycle**. Phase A dominates the calendar.

## §5 — Risk register (high-level; per-phase detail in plan docs)

| ID | Risk | Mitigation |
|---|---|---|
| F1 | Phase A.3 feature branch + parallel main work creates merge conflicts | Periodic rebase against main during A.4; pause main-side work if conflicts grow |
| F2 | Phase A.4f c_api Val simplification breaks ADR-0109 facade design | ADR-0109 facade Value section updated in same cohort (A.4f scope) |
| F3 | Phase B SEH bridge requires C/asm — not Zig-pure | Standalone C file alongside Zig, build.zig integration |
| F4 | Phase E collab review surfaces a regression Phase A-D missed | Phase E is the design-of-record audit; if regression found, loop returns to Phase B/D as needed (Phase E is not bucket-2 stop) |
| F5 | bench regression for scalar-only modules (Value doubling) | Phase 8b discipline applies; Phase A.6 captures bench delta; if > 5% regression on representative fixture, investigate hot-path optimization |
| F6 | Phase C / D find ADRs with conflicting Status text after Phase A.6 | Phase C is structured to catch these; ADR Status canonical pass = check_adr_history.sh + manual review |

## §6 — Cycle + time estimate

| Phase | Cycle count | Calendar (autonomous) | Gated by |
|---|---|---|---|
| A | 9-12 | ~3-7 days | autonomous |
| B | 3-5 | ~1-2 days | autonomous (parallel-able with A) |
| C | 1-2 | ~hours | autonomous |
| D | 1 | ~hours | autonomous |
| E | 1 user cycle | 1 session | **user collab** |
| F | 1 (open) | ~hours | autonomous |
| **Total** | **15-21 + 1 user** | **1-3 weeks autonomous + 1 user session** | |

## §7 — References

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a +
  §6 — canonical iteration discipline + exit predicate.
- [`phase9_value_widen_plan.md`](./phase9_value_widen_plan.md)
  — §9.13-V (Phase A) implementation playbook with
  per-sub-phase detail + test plan + risk register.
- [`decisions/0110_value_widen_to_16_byte.md`](./decisions/0110_value_widen_to_16_byte.md)
  — Phase A design record. Accepted 2026-05-24.
- [`decisions/0104_phase9_honest_accounting_reframe.md`](./decisions/0104_phase9_honest_accounting_reframe.md)
  — Phase 9 真スコープ + invariant gate mechanism (Revision
  2026-05-24 entry adds §9.13-V to scope).
- [`decisions/0109_native_zig_api_inversion.md`](./decisions/0109_native_zig_api_inversion.md)
  — ADR-0109 native Zig API; Phase F drives the rewrite.
  Phase A.4f simplifies the facade Value section in
  ADR-0109 as a byproduct.
- [`../docs/runtime_deep_comparison.md`](../docs/runtime_deep_comparison.md)
  — 8-runtime industry audit that triggered the Phase A
  reframe.
- ROADMAP §9 — rows `9.12-F`, `9.12-I`, `9.13-0`, `9.13-V`,
  `9.13` are all `[ ]` as of cycle 37; this doc shows how
  they close.

## §8 — Revision history

- 2026-05-24 — Initial draft at cycle 37, post-ADR-0110
  Accept. Created as user-requested "flow + supplementary
  reference" — committed instead of staying in chat scratch
  so it survives session boundaries and is discoverable
  from handover.md cold-start.
