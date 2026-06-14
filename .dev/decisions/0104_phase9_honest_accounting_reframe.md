# 0104 — Phase 9 honest-accounting reframe: revert premature [x] flips + adopt master plan §3 Tier-0 designs

- **Status**: Accepted
- **Date**: 2026-05-22
- **Author**: Shota Kudo + 2026-05-22 4-agent audit aggregation
- **Tags**: roadmap, governance, phase-9, honest-accounting, exit-criterion

## Context

Phase 9's exit criterion (per ROADMAP §9 row + Phase Status widget)
is "Wasm 1.0 + 2.0 (incl. SIMD) **literal 100%** (skip-impl == 0
across spec + edge_cases + realworld + differential) **on 3 hosts**".

On 2026-05-22, the autonomous `/continue` loop flipped three ROADMAP
sub-rows `[x]`:

- §9.13-0 (Cat IV — windowsmini reconcile sweep) at `5b972565`
- §9.12-F (Phase-9-eligible debt cohort) at `d771356f`
- §9.12-I (ADR + lesson + private/ closure) at `d771356f`

User asked "ほんとうに Phase 9 完遂か?" and a 4-parallel-subagent
audit was launched. The audit findings (compiled into
`.dev/phase9_close_master.md` §2):

1. **§9.13-0 row exit text** ("windowsmini full `test-all` green ...
   **bit-identical with Mac + ubuntunote**") is **literally false**:
   - Mac+ubuntunote: `spec_assert_runner_non_simd 25401 PASS / 0 skip-
     impl / 525 skip-adr`
   - Windows: `23427 PASS / 0 skip-impl / 2499 skip-adr` (1974 extra
     SKIP-WIN64-* + SKIP-NO-LINK-TYPECHECK)
   ADR-0078 redefined these as `debt-trackable SKIP tokens` but the
   ROADMAP exit text was never amended; row was flipped on the
   redefined criterion while text still claimed the original.

2. **The Win64 SKIP tokens are workarounds, not legitimate
   out-of-scope deferrals**. v1 and wasmtime both PASS the same
   fixtures via different design choices:
   - D-162 `SKIP-WIN64-EXHAUSTION` (15 directives): v1 + wasmtime
     use **JIT-prologue stack-probe**, bypassing hardware
     `EXCEPTION_STACK_OVERFLOW` entirely. v1: `src/x86.zig:2708-2722`
     + `src/jit.zig:6464`. wasmtime:
     `crates/cranelift/src/func_environ.rs:204-211` +
     `crates/cranelift/src/isa_builder.rs:26-29`.
   - D-164 `SKIP-WIN64-MULTI-RESULT` (3171 directives): v1 uses
     `[*]u64 regs` buffer-write entry ABI (`src/vm.zig:33`),
     wasmtime/cranelift uses uniform implicit-SRet ABI lowering
     across SysV and Win64 Fastcall
     (`cranelift/codegen/src/isa/x64/abi.rs:101, 118-135, 345-351`).
     Per-shape inline-asm thunks (zwasm v2's current band-aid path)
     is adopted by neither.
   - D-163 `SKIP-WIN64-CALL-INDIRECT-TRAP` (10 directives): wasmtime
     uniform VEH-AV path; this is a narrow zwasm codegen bug in
     `op_call.zig::emitCallIndirect` Win64 branch.
   - wasmtime test-util (`crates/test-util/src/wast.rs:59-69, 380-425`)
     has **ZERO Windows-conditional skips** for core Wasm 1.0/2.0
     fixtures. Industry standard is 3-host equivalent.

3. **§9.12-F exit ("debt active rows < 15") was amended by ADR-0102
   to per-row predicate (a)/(b)/(c)/(d)** but the ROADMAP row text
   was never amended; flip was on ADR-0102 predicate while text said
   literal "< 15".

4. **§9.12-I exit criteria were technically met** (`check_adr_history.sh
   --gate` exit 0, `check_lesson_citing.sh` 0, ADR Accepted 35 → 29)
   but the broader hygiene work (D-149 SHA backfill, skip-ADR Status
   wording cleanup, 4 close-plan docs not archived, p9_completion_
   progress.yaml drift) was deferred without explicit ADR-0102-style
   amendment.

5. **c_api / Zig API Wasm-2.0 utilisation tests are missing**:
   `wast_runtime_runner` is not in `test-all` (`build.zig:454`); Wasm-
   2.0 reftype c_api round-trip, mixed-export iteration, bulk-trap via
   c_api, cross-module funcref via `wasm_instance_new` imports — all
   zero coverage. ADR-0025 Zig facade
   (`zwasm.Runtime`/`Module`/`Instance`/`Value`) is unimplemented.
   These were filed as Phase-16-deferred (D-075 / D-079 / D-139) but
   the **utilisation-test layer for Wasm 2.0 features is Phase-9-scope**
   per user direction (2026-05-22):
   > "c api / zig api の wasm 2.0 時点での利用テスト分は完備されて
   > いる必要がある"

6. **6 ADR Revision history rows had backfill-pending SHA placeholders**
   (0064, 0062, 0071, 0098, 0100, 0101); 17 §9.x rows have bare
   `[x]` without commit SHA pointers.

User direction (2026-05-22, in order):

> 結局全部やるべきです。今表示いただいた Tier 1, Tier2 も含めて、
> 完全に綺麗にしてから Phase 9 を閉じる。AI が終わりそう⇒終わってない
> を何ターンもやりとりし続けてうんざりしつづけているので、増えすぎた
> debt や指示、skills, rules, hooks を誤解がないシンプルなパスに
> まとめることを今、やって、その後、今の残り課題を再現性があるように
> (新セッションから迂回できない原理的な仕組みをつくっておきたい。
> すべて、このセッション中に、次回クリアセッションから取り組めるように
> 配線しておいてほしい。セルフレビューは非常に重要なので、「既存の
> 整理」⇒ 2 回セルフレビュー (プラグイン利用) ⇒ 新しい Phase 9 の
> 指示の調査と書き出しと配線 ⇒ 2 回セルフレビューをしてください。

And earlier (Tier 0 design decision):

> JIT prologue stack-probe + buffer-write ABI 決心 — v1/wasmtime
> 証拠ベースで D-162/D-164 の設計 ADR を起案して honest に実装。

## Decision

### D1 — Phase 9 close exit criterion (this ADR's load-bearing rule)

Phase 9 = DONE requires ALL of:

1. `bash scripts/check_phase9_close_invariants.sh --gate` exit 0
   (script lands per this ADR; see §"Implementation" below).
2. windowsmini `test-all` green WITHOUT any `SKIP-WIN64-*` token
   emission. The `SKIP-WIN64-EXHAUSTION` / `-CALL-INDIRECT-TRAP` /
   `-MULTI-RESULT` arms in `test/spec/spec_assert_runner_base.zig`
   are **removed** by Tier-1 land (per ADR-0105 + ADR-0106 — both
   filed concurrently as Proposed; user flips to Accepted at §9.13
   gate review).
3. `test/api/c_api_wasm2_*.zig` (reftype + bulk-traps + mixed-exports)
   + `test/runners/fixtures/cross_module_funcref/` + Zig facade
   minimum subset in `src/zwasm.zig` (`Runtime` / `Module` / `Instance`
   / `Value`) + `test/api/zig_facade_wasm2.zig` are landed and green.
4. `wast_runtime_runner` is in `test-all` (build.zig:454 amendment).
5. `.dev/debt.md` has zero `blocked-by: <trigger-not-fired for
   Phase-9-scope feature>` rows (D-094 / D-062 closed via Tier-1
   implementations).
6. ADR-0105 (JIT-prologue stack-probe) + ADR-0106 (multi-result ABI
   redesign) `Status: Accepted` at §9.13 hard gate review.
7. §9.13-0 / §9.12-F / §9.12-I re-flipped `[x]` with cited SHAs.
8. §9.13 🔒 Phase 10 entry gate cleared.

### D2 — Revert the 3 premature [x] flips

Per the audit findings, the `5b972565` (§9.13-0) + `d771356f`
(§9.12-F + §9.12-I) flips were made on **drift-amended** criteria
(ADR-0078 SKIP redefine + ADR-0102 per-row predicate) without the
corresponding ROADMAP row text being amended. The honest accounting
is:

- §9.13-0 reverts to `[ ]` until the Win64 SKIP-* tokens are removed
  (per D1.2).
- §9.12-F reverts to `[ ]` until D-094 + D-062 are closed (per D1.5)
  — workaround-masquerade reframing per audit Agent 3 §E.
- §9.12-I reverts to `[ ]` until D-149 SHA backfill + skip-ADR
  Status cleanup + close-plan archive + stale-ref fix all land
  (per D1 broader hygiene set).

The `phase_log/phase9.md` 9.13-0/9.12-F/9.12-I entries (250/252/253)
are amended **in-place** with `**REVERTED 2026-05-22 per ADR-0104**`
notation so the historical record stays honest.

### D3 — Adopt master plan §3 Tier-0 designs

User's Tier-0 direction (2026-05-22):
- D-162 fix: **JIT-prologue stack-probe** (per v1 + wasmtime
  precedent). Documented in detail in **ADR-0105**.
- D-164 fix: **buffer-write entry ABI** or **uniform implicit-SRet
  ABI lowering** (final pick by user at §9.13 gate review).
  Documented in detail in **ADR-0106**.
- Per-shape Win64 inline-asm thunks (current D-164 plan) is
  **REJECTED** as band-aid that scales linearly with new return
  shapes; neither v1 nor wasmtime adopts it.
- "Wait for trigger" framing on D-094 / D-062 is **REJECTED** —
  the audit reframed these as workaround-masquerade
  (mechanical-precedent-exists rows mis-labelled as
  trigger-not-fired). Status is now `now`-eligible Phase-9-scope
  work.

### D4 — Workflow discipline

User's 4-phase workflow:

1. **Existing-organization cleanup**: archive 5 close-plan docs +
   `Doc-state:` 4-state vocabulary rule + outbound ref sed +
   stale-path fixes + skip-ADR Status flips + spike cleanup +
   premature [x] revert + workaround-masquerade debt reframe.
2. **Self-review × 2** (subagent): audit-findings coverage check
   + fresh-session walkability dry-run.
3. **New Phase 9 wiring**: ADR-0105 + ADR-0106 Proposed drafts +
   `.claude/rules/phase9_close_invariants.md` (auto-load) +
   `scripts/check_phase9_close_invariants.sh` (gate-fail until
   Tier-1 lands) + ROADMAP §9.13 row body amendment + SKILL.md
   Resume Step 5d.
4. **Self-review × 2** (subagent): fresh-session walkability
   verification + new-contradiction sweep.
5. **handover.md refresh** as canonical fresh-session entry.

### D5 — Fresh-session non-bypassability

Per user "新セッションから迂回できない原理的な仕組み":

- `.claude/rules/phase9_close_invariants.md` is **auto-loaded**
  whenever `.dev/ROADMAP.md` / `.dev/handover.md` / `.dev/debt.md`
  / `test/spec/spec_assert_runner_base.zig` is edited.
- `scripts/check_phase9_close_invariants.sh` is **auto-run** at
  `/continue` Resume Step 5d (new sub-step, master plan §4 Phase
  C).
- Attempting to mark §9.13-0/F/I `[x]` while the invariant script
  FAILs is a `§18.3` violation per this ADR — the audit found
  that previous premature flips happened because no such
  invariant existed.

## Alternatives considered

### Alternative A — Amend the ROADMAP exit texts (keep [x] flips)

- **Sketch**: Per ADR-0078 + ADR-0102, the criteria for §9.13-0
  and §9.12-F have evolved. Just amend the row texts in-place to
  reflect the current predicate (e.g. "Exit: `check_phase9_close_
  invariants.sh --gate` exit 0 per ADR-0078"). Keep `[x]` since
  the **amended** criterion was met.
- **Why rejected**:
  1. User direction explicitly rejected this: "結局全部やるべき。
     完全に綺麗にしてから Phase 9 を閉じる。" The amend-and-keep
     path leaves D-162/D-163/D-164/D-094/D-062 unaddressed.
  2. The audit found that **the SKIP tokens themselves are
     workarounds**, not legitimate deferrals — amending the
     ROADMAP to legitimize them re-derives the
     `no_workaround.md` failure mode the project has codified
     against.
  3. v1 + wasmtime precedent shows the fixes are bounded
     Phase-9-scope work (JIT-prologue stack-probe + uniform
     implicit-SRet / buffer-write ABI), not multi-phase epics.

### Alternative B — Carve out the Win64 SKIPs in a new ADR + close Phase 9

- **Sketch**: New ADR carves D-162/D-163/D-164 out of Phase 9
  scope as "Windows: build + unit-test only; spec corpus on Mac +
  Linux for Phase 9". §9.13-0 `[x]` stays; row text amended to
  reflect carve-out; Phase 9 closes; Win64 spec work becomes
  Phase 10+.
- **Why rejected**:
  1. User direction: "Phase 9 = Wasm 2.0 on 3 hosts at 100%" —
     carving out windowsmini contradicts the project's own
     scope. v1 had 3-host parity; v2 dropping it would be a
     regression in standards.
  2. Industry standard (wasmtime / v1) has 3-host parity for
     these fixtures; the v2 implementation gaps are
     identifiable and bounded (per ADR-0105 + ADR-0106).
  3. The carve-out would normalise the workaround-masquerade
     pattern at the Phase-boundary level; future audit cycles
     would find Phase 10+ rows similarly drift-amended.

### Alternative C — Leave it as-is (3 rows flipped, master plan documents work)

- **Sketch**: Accept that §9.13-0/F/I are flipped against
  current-state predicates; future Tier-1 work happens under
  Phase 10 banner with master plan citing the gaps.
- **Why rejected**:
  1. User direction explicitly forbids this (rejected as
     "AIが終わりそう⇒終わってないのうんざりループ").
  2. Phase Status widget would advance to `9 | DONE` next time
     §9.13 [x] fires — locking in the dishonest accounting at a
     project-history level.
  3. The audit's structural-precedent finding (v1 + wasmtime
     PASS) makes "deferral" indefensible.

## Consequences

### Positive

- **Honest accounting**: Phase 9 status now reflects what was
  actually built (Wasm 2.0 on Mac + ubuntunote; Win64 with 3
  Wasm-1.0-core MUST-PASS gaps; c_api/Zig facade Wasm-2.0
  utilisation untested).
- **Industry-standard convergence**: the chosen designs (per
  ADR-0105 + ADR-0106) match v1 + wasmtime — easier to maintain,
  easier to teach (P10 "textbook"), more robust to future Wasm
  proposals (multi-value extensions, etc.).
- **Fresh-session reproducibility**: the
  `phase9_close_invariants.md` rule + `check_phase9_close_
  invariants.sh` gate make the audit findings **structurally
  unbypassable**. A clean session starting from CLAUDE.md →
  handover.md cannot mark §9.13-0 [x] without the underlying
  work landing.
- **Doc-state hygiene**: `.dev/archive/phase9/` collects the 5
  superseded close-plan docs with `Doc-state: ARCHIVED` markers;
  outbound refs updated to new paths; the `Doc-state:` 4-state
  vocabulary rule (`.claude/rules/doc_state_marker.md`) prevents
  this drift class from recurring.

### Negative

- **Phase 9 close delayed by N cycles** (N depends on ADR-0105 /
  ADR-0106 implementation cost). User accepted this trade-off
  explicitly.
- **3 phase_log entries with REVERTED notation** look messy but
  are historically honest — the alternative (deleting the
  entries) would erase the lesson.
- **Multi-cycle autonomous loop ahead** — Tier-1 implementations
  (JIT-prologue stack-probe + multi-result ABI redesign +
  c_api/Zig API tests + workaround-masquerade debt close)
  require autonomous loop cycles. ADR-0076 D2 single-push +
  ubuntu kick discipline applies.

### Neutral

- **Master plan doc** (`.dev/phase9_close_master.md`) becomes the
  authoritative source. Replaces 5 archived close-plan docs.
- **ADR-0103 path (a)** (`_resetstkoflw` MSVCRT quick fix)
  is **demoted to Rejected** by ADR-0105's path (b)
  (JIT-prologue stack-probe). ADR-0103 itself stays Accepted as
  the SEH-bridge-design ADR; its Consequences section is amended
  via Revision history to cite ADR-0105 superseding path (a).

## Implementation

This ADR is META — its implementation is the entire 4-phase
workflow (D4). Concrete artefacts that land as part of this ADR:

- `.dev/phase9_close_master.md` (authoritative remaining-work
  source).
- `.dev/archive/phase9/` (5 archived close-plan docs).
- `.claude/rules/doc_state_marker.md` (4-state vocabulary).
- `.claude/rules/phase9_close_invariants.md` (auto-load,
  Phase-9-DONE invariant list).
- `scripts/check_phase9_close_invariants.sh` (gate-fail until
  Tier-1 lands).
- ROADMAP §9.13-0 / §9.12-F / §9.12-I `[x]` → `[ ]` revert
  (this ADR's load-bearing edit).
- ROADMAP §9.13 row body amendment citing this ADR + the
  invariant script.
- `phase_log/phase9.md` 9.13-0/9.12-F/9.12-I entry REVERTED
  notation.
- `.dev/handover.md` refresh (canonical fresh-session entry).

Companion ADRs:
- **ADR-0105**: D-162 JIT-prologue stack-probe (Proposed at this
  cycle; user flips Accepted at §9.13 gate review).
- **ADR-0106**: D-164 multi-result ABI redesign (Proposed; user
  picks (a) buffer-write or (b) uniform implicit-SRet at §9.13
  gate review).

## Removal condition

This ADR's discipline is permanent (Phase-9-DONE invariants stay
load-bearing until Phase 9 closes for real). When Phase 9 =
DONE per D1, this ADR's Status flips to `Closed (Phase 9 DONE)`
+ Revision history cites the closing SHA. The `phase9_close_
invariants.sh` gate then becomes a permanent regression check
(repurposed for future Phase boundaries if useful).

## References

- `.dev/phase9_close_master.md` (authoritative remaining-work
  inventory).
- 2026-05-22 4-agent audit aggregation:
  - Agent 1 (SKIP justification): `private/audit-2026-05-22-skip-justification.md`
    (if persisted) or chat transcript at session ID
    `06daf781-f558-47b0-a375-7ae4f4e175ed`.
  - Agent 2 (c_api/Zig API coverage).
  - Agent 3 (doc/debt/ADR critical re-read).
  - Agent 4 (v1/wasmtime/testsuite comparative survey).
- v1 reference: `~/Documents/MyProducts/zwasm/src/x86.zig:
  2708-2722` (stack-probe), `~/Documents/MyProducts/zwasm/src/
  vm.zig:33` (buffer-write entry ABI), `~/Documents/MyProducts/
  zwasm/src/jit.zig:6464`.
- wasmtime reference: `~/Documents/OSS/wasmtime/crates/cranelift/
  src/func_environ.rs:204-211, 3664-3672`, `~/Documents/OSS/
  wasmtime/crates/cranelift/src/isa_builder.rs:26-29`,
  `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/x64/
  abi.rs:101, 118-135, 218-224, 345-351`, `~/Documents/OSS/
  wasmtime/crates/test-util/src/wast.rs:59-69, 380-425, 464-509`.
- ADR-0078 (SKIP taxonomy — redefined `debt-trackable` class).
- ADR-0102 (§9.12-F exit reframe to per-row predicate).
- ADR-0103 (Win64 SEH bridge — path (a) demoted by ADR-0105).
- ADR-0105 (companion — JIT-prologue stack-probe; Proposed at
  this cycle).
- ADR-0106 (companion — multi-result ABI redesign; Proposed at
  this cycle).
- `.claude/rules/no_workaround.md` (the failure mode this audit
  surfaced).
- `.claude/rules/no_fallback_on_failure.md` (sibling).
- `.dev/lessons/2026-05-21-debt-stale-framing-pattern.md` (the
  workaround-masquerade pattern at debt level).

## Revision history

| Date       | Commit       | Change                                          |
|------------|--------------|-------------------------------------------------|
| 2026-05-22 | `fca7fe1c` | Initial draft + Accepted same cycle (this commit) |
| 2026-05-24 | (this commit) | **Phase 9 scope expansion — §9.13-V (Value widen to 16-byte) added** per user direction 2026-05-24 cycle 37 (cycle 36-37 reframe: ADR-0052 cope mechanism + ADR-0107 c_api propagation = ongoing maintenance debt for v128; Value=16 widen is "pay once, never again" per `docs/runtime_deep_comparison.md` industry audit). ADR-0110 Accepted; §9.13-V row added to ROADMAP §9; D-079 (ii) blocked-by re-targeted from ADR-0107 (Withdrawn) to ADR-0110 implementation. Phase 9 = DONE now ALSO requires §9.13-V completion (in parallel with §9.13 hard gate; either order). Plan doc: `.dev/phase9_value_widen_plan.md`. |
| 2026-05-23 | (prior commit) | **Phase 9 scope expansion — D-157, D-079, D-139 promoted to Phase 9 真スコープ** per user direction 2026-05-23. The original ADR-0104 (and its companion `.dev/phase9_close_master.md` §5/§6) framed only the Win64 SKIP-WIN64-* trinity (D-162/D-163/D-164) + c_api/Zig API minimum subset (I2/I3) as Phase-9-eligible. User re-audit identified 3 debt rows that were `blocked-by: Track-D / v0.1.0 RC` but are structurally Phase 9 scope under the "Wasm 2.0 complete + Zig/C API complete at Phase 9 release time" rubric: (i) **D-157 SKIP-NO-LINK-TYPECHECK** — 56 Wasm 2.0 spec corpus `assert_unlinkable` fixtures skipped because `instantiate.zig` doesn't link-time-check non-func (table/memory/global) import types; this is Wasm spec MUST — not legitimate deferral; (ii) **D-079 v128 cross-module imports c_api Instance path** — spec-runner side discharged at §9.12-E, but c_api `Runtime.globals: []*Value` scalar-only layer means `wasm_instance_new` can't carry v128 cross-module globals; "C API完備 at Phase 9 release" requires v128-aware globals; (iii) **D-139 spec_assert bypass c_api Instance path** — `wast_runtime_runner` smoke step in test-all is I4-min but spec_assert runners still use direct `JitRuntime` stamping, leaving c_api Instance lifecycle (zombie list, arena ownership, Store binding) under-exercised — strict "C API complete" needs spec_assert bridge OR equivalent c_api per-feature unit fixtures. Master plan §5 + §6, ROADMAP §9.13-0 exit criterion, and the corresponding debt rows are amended in the same commit to reflect the expanded Phase 9 scope. Phase 9 = DONE now requires: D-165 close + D-157 implementation + D-079 c_api side + D-139 c_api Instance coverage, in addition to the prior conditions. |
