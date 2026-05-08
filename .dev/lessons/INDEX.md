# Lessons index

> Lightweight "we tried this and learned X" notes. Lessons are **not
> ADRs** — they record observations, spike outcomes, and re-derivable
> design intuitions that don't justify a load-bearing decision
> document but should not be lost across sessions.
>
> See `.claude/rules/lessons_vs_adr.md` for the decision tree
> distinguishing lesson from ADR.

## How to use this file

1. Before starting a non-trivial task, **grep the keyword column**
   below for the area you're about to touch (interpreter,
   cross-module imports, ABI, build.zig, etc.). If a lesson exists,
   read it first.
2. After a spike or surprise, add a row here AND drop the lesson
   file under `.dev/lessons/<YYYY-MM-DD>-<slug>.md`. Keep the file
   ≤ 50 lines.
3. If the same lesson is cited in 3+ places (commits / ADRs / chat
   transcripts), promote to ADR per the lessons-vs-ADR rule.

## Index

| Date       | Slug                                  | Keywords                                                       | One-line                                                                                              |
|------------|---------------------------------------|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| 2026-05-04 | beta-funcref-encoding-rejected        | funcref, Value.ref, instance identity, cross-module dispatch   | Beta-style packed (instance_id, funcidx) was originally preferred on aesthetics; survey of wasmtime + wazero revealed Alpha (zombie keep-alive) is industry-standard. Beauty-driven design loses to 10 years of production experience. |
| 2026-05-04 | autoregister-spike-regression         | wast_runtime_runner, register, embenchen, linking-errors       | Mirroring wasmtime's `(module $X ...)` → bare-name auto-register made 4 embenchen pass but regressed 9 linking-errors fixtures (5→14 fails); root cause is c_api's import-type validation gap, not the auto-register itself. |
| 2026-05-04 | if-result-merge-point-bug             | jit emit, if/else/end, operand stack, merge points, CFG join   | `(if (result T))` returns junk for the cond=1 path — emit pass naively pushes both arms' result vregs but only the post-branch top survives. Workaround: use locals to merge; structural fix needs merge-aware label stack. |
| 2026-05-04 | emit-monolith-cost                    | emit.zig, file size, §A2, refactor, Phase 7, 9-module split    | emit.zig grew to 3989 LOC across Phase 7 sub-rows without a refactor; should have split at the 1000-LOC soft cap. Records the proposed 9-module split for §9.7 / 7.5d sub-deliverable b. |
| 2026-05-04 | liveness-stage-extension-debt         | liveness, if/elif chain, frame-based dispatch, ROADMAP §A12    | Liveness handlers grew via if/elif/elif chains across phase boundaries; frame-based dispatch (the §A12 pattern but for analysis) restructure deferred to next liveness-touch cycle. |
| 2026-05-04 | adr-0017-merge-blind-spot             | ADR-0017, CFG join points, X19 amendment, design completeness  | ADR-0017 didn't anticipate `(if (result T))` join semantics; the X19 amendment hid the original incompleteness. Honest framing rule (gap vs refinement) needed in Revision history. |
| 2026-05-04 | adr-revision-history-misuse           | ADR amend, Revision history, README convention, gap vs refinement | ADR Revision history rows have read like "minor refinement" when they were actually "we missed this at design time". Proposes sharper categorisation: gap / refinement / expansion. |
| 2026-05-04 | adr-batch-dependency-order            | ADR batch, dependency DAG, Phase 7 reshape, lineage             | 4-ADR batch (0017-0020) had implicit dependency order; should have added Dependencies sections or a meta-DAG ADR for 3+ ADR batches. |
| 2026-05-06 | regalloc-pool-size-mismatch           | regalloc, max_reg_slots, abi.allocatable_gprs, ADR-0027, SlotOverflow | regalloc default `max_reg_slots = 9` was not updated when ADR-0027 reduced `allocatable_gprs.len` 9 → 8. Result: func[9] of local_get.0 hit `SlotOverflow` (slotToReg returned null for slot 8). Cross-module config-sync rule needed. |
| 2026-05-06 | spec-citation-gap                     | Wasm spec citation, per-handler doc, late-surface bugs, D-033, prologue zero-init | Two basic Wasm spec requirements (D-033 i64 width-aware local.get/set/tee, prologue local zero-init §4.5.3.1) reached production without unit-test coverage because handler authoring described **what** the code does, not **what the spec demands**. Codified as `.claude/rules/spec_citation.md` — every spec-semantic handler now requires a `Wasm spec §X.Y` line in its docstring. |
| 2026-05-07 | merge-tri-state-regression            | Label widening, ?T → buffer+count, dual-axis slot, D-035-c regression, dead-code merge | When widening a single-result `?u32` to multi-result `[N]u32 + count`, dropping the implicit "did capture happen" tri-state is a silent regression vector. Need an explicit `captured: bool` field per `single_slot_dual_meaning.md`. Surfaced 68 spec_assert FAILs that test-all didn't catch (D-040 — wire test-spec-assert in). |
| 2026-05-07 | validator-dead-code-in-runtime        | D-042, validator wiring, compileOne, module context, type-mismatch | `compileOne` skips validator entirely (validator is dead code in JIT runtime path). Naive wire-in passing empty globals/tables/data slices fixes 27 D-042 fixtures but breaks 69 valid fixtures that use globals/tables/memory. Discharging D-042 requires threading module context (globals/tables/data/elem_count) through compileOne signature first. |
| 2026-05-08 | file-size-blindspot                   | §14, A2 hard cap, emit.zig, debt acknowledgment vs enforcement, meta_audit Phase 7 | Phase 7 closed with 3 active §14 file-size hard-cap violations — autonomous loop interpreted "acknowledged + tracked" as "fine to continue", inverting §14's "forbidden" semantics. Surfaces a CHECKS / LOOP gap: hard-cap violations should escalate from `watch` to `block` at phase boundaries; per-task Step 5 should pause when emit-side files cross the cap. Worked example the meta_audit skill was designed to catch. |

## Promotion to ADR — when to escalate

A lesson promotes to ADR when **any** are true:

- The same lesson has been cited (in commit messages, code comments,
  ADR Alternatives sections) 3+ times.
- The lesson contains a load-bearing decision (one path adopted,
  alternatives explicitly rejected, removal condition spelled out).
- A subsequent ROADMAP / Phase / scope decision rests on the lesson.

Promotion procedure: open `.dev/decisions/NNNN_<slug>.md` with the
lesson content as Context, write the Decision / Alternatives /
Consequences sections, then **delete** the lesson file (the ADR
supersedes it). Update this INDEX accordingly.

## Stale-ness policy

- Lessons that are 6 months old and have never been re-read are
  candidates for archival, **not** deletion. Move to a yearly
  `.dev/lessons/archive/<year>/` subdir; keep the INDEX row but
  shorten the keywords if more recent lessons cover the same area.
- `audit_scaffolding` skill is responsible for periodically
  validating that each lesson row's referenced commit / ADR / file
  path still exists.
