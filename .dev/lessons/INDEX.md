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
| 2026-05-08 | lint-debt-at-phase-close              | lint, no_unused, require_exhaustive_enum_switch, Phase 7 close, pre-commit advisory | Phase 7 close commit (`9da3c99`) landed with 8 pre-existing lint warnings (5 no_unused + 3 enum-switch). Same CHECKS / LOOP shape as file-size-blindspot — pre-commit gate list is documentation, not enforced (no `.git/hooks/pre-commit`); autonomous loop must fail-fast on Step 4 lint gate exit-1. Discharged in §9.8 / 8.1-a. |
| 2026-05-08 | hoist-vreg-semantic                   | hoist, ZIR vreg, operand-stack, liveness push order, frame scope, ADR-0031 | §9.8 / 8.4-c discovered that ZIR vreg IDs are renumbered by liveness based on operand-stack push order; naive instr-move (the 8.4-b MVP) breaks all downstream vreg references when integrated. Wasm's frame-scoped operand stack also makes hoist-out-of-loop semantic incorrect at the IR level. Correct hoist requires `*.const K; local.set N` rewrite. ADR-0031 amended; D-053 tracks the redesign. |
| 2026-05-09 | hoist-branch-targets-as-pc            | hoist, branch_targets, depth vs PC, single-axis-mistake, br_table, ADR-0031, D-053 | §9.8a / 8a.5 D-053 root cause: hoist/pass.zig PC-shifted `branch_targets[]` entries that are actually Wasm block-stack depths. Cap=4 masked the bug (small shifts coincidentally hit valid depths). Cap > ~10-20 inflated depths past `labels.items.len`, surfacing as `br_table UnsupportedOp` on 10/55 realworld fixtures. Lesson: single-type-two-axes (PC vs depth) failure mode + small-input-test-as-mask anti-pattern. |
| 2026-05-09 | greedy-local-already-does-reuse       | regalloc, greedy-local, slot reuse, busy-mask, survey-vs-code, ADR-0037 | §9.8b / 8b.2-c discovery: `regalloc.compute`'s busy-mask check `earlier.last_use_pc > r.def_pc` is an inline slot-reuse mechanism. Survey misread "greedy-local" as "no reuse". ADR-0037 Option 1 framing redundant in result; refactor stands as compile-time speedup + Phase 15 coalescer substrate. Real bench-delta wins migrate to class-aware allocation (D-036 §option-b) + live-range splitting (Phase 15). |
| 2026-05-09 | v1-monolith-file-survey-miss          | textbook-survey, v1-survey, monolith-files, shallow-investigation, simd, file-name-vs-content | Mid-session v1/v2 SIMD comparison concluded "v1 SIMD is essentially zero implementation" by reading `simd_arm64.zig` / `simd_x86.zig` (15 LOC stubs) without grepping the wider tree. Real impl was in jit.zig (8.7k LOC, 124 NEON encoders) + x86.zig (7.5k LOC, 185 SSE encoders) + opcode.zig SimdOpcode enum + 3 conformance fixtures. v1's monolith convention means topic-named files can be aspirational extraction stubs; v2's split discipline does NOT apply to v1. textbook_survey.md amended with monolith-trap caveat. |

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
