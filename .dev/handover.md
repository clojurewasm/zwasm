# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`phase9_close_master.md`](./phase9_close_master.md)
§5.3a (Phase A + Phase B 2-stage iteration discipline).

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`.

**Phase 9 close gate (mac-host)**: **18/18 PASS** (was 17/18
pre-cycle-20). I1 satisfied — no SKIP-WIN64-* emission.

**Test state**: Mac+ubuntu test-all green at last code
commit (9f0517cd); windowsmini has D-167 ~11 directive fails
unrelated to Phase 9 close gate.

Closed cycles 10-25: `git log --grep="cycle 2[0-5]\|A1\|A2\|A4"`.

## Cycles 26-34 progress (see `git log --oneline`)

- 26-28: D-167 spike step 1 COMPLETE.
- 29-30: D-167 wire-up blocked by entry.zig cap →
  D-168 + ADR-0108 drafted.
- 31: stale-comment cleanup.
- 32-34: ADR-0107 + ADR-0108 enrichment passes
  (Alt. D + 9 catalog precedents + 4 hazards).
- 35: user opted per-file cap override → ADR-0099
  amended (Revision 2026-05-24) + ADR-0108 Withdrawn
  + D-168 discharged + entry.zig marker cap=3000.
- 36: CW v2 dogfooding reframe — c_api veneer →
  native Zig facade inversion. Drafted **ADR-0109**
  + `docs/zig_api_design.md` (CW-AI 渡し用 spec).
- 37a: 8-runtime industry audit (3 parallel subagents)
  → `docs/runtime_deep_comparison.md` (399 行). v128
  importance + 128-bit terminal width 検証。
- 37b: **ADR-0110 Accepted** — Value extern union を
  8-byte → 16-byte に widen (v128 first-class、
  pay-once-never-again)。**ADR-0107 Withdrawn** (cope
  ではなく root-cause-fix)。**ADR-0052 cope-portion
  superseded**。**ADR-0104 Revision 2026-05-24** で
  Phase 9 真スコープに §9.13-V cohort 追加。
  Plan doc: `.dev/phase9_value_widen_plan.md` (6 sub-
  phase / 9-12 cycle / test coverage 強化を Phase 2
  に明示)。ROADMAP §9.13-V row 追加。
- 38: **§9.13-V Phase A.1 (scope audit) CLOSED**.
  REPORT at `private/spikes/value-widen-scope-audit/REPORT.md`
  (gitignored, spike discipline)。ADR-0052 "50+ test sites"
  claim **inflated ~25×** に検証。ADR-0110 §1.66-75 の cope
  list 中 4項目 (globals_byte_storage / globals_byte_base /
  evalConstScalarValue / evalConstV128Value) は **phantom**
  (tree 不在) に検証。Phase 4d/4e はほぼ空、Phase 4g
  (spec runner unification, 26 sites) が新 long pole に判明。
  plan doc §2 Phase 1 + §4 risk register (R8/R9/R10 追加、
  R1 dissolved、R2 downgraded) + §5 cycle estimate + §8
  revision history 更新。
- 39: **§9.13-V Phase A.2.1 — Value-layer scalar boundary
  fixtures landed** (5 WAT/wasm/expect triples at
  `test/edge_cases/p9/value_semantics/`): i32/i64 INT_MIN
  via global, f64 NaN payload via global (non-canonical via
  reinterpret_i64), f32/f64 -0 via global。全 Value=8 baseline
  green。Side-find: build.zig で run_edge_p9 が test_all_step
  に wired されていなかった (test_edge_step 経由のみ); 1-line
  fix で p9 corpus 全 60 fixture が test-all に組み入れ。
- 40: **§9.13-V Phase A.2.2 — v128 global cope-path boundary
  fixtures landed** (8 fixtures): 6 shape round-trips
  (i8x16/i16x8/i32x4/i64x2/f32x4/f64x2 lanes 0+MAX via global)
  at `test/edge_cases/p9/v128_lane_ops/` + 2 NaN-payload
  preservation (f32x4 / f64x2 non-canonical NaNs) at
  `v128_nan_payload/`。全 ADR-0052 cope-state baseline green。
  Phase A.4g unification の behaviour-preservation contract が
  これで成立。p9 corpus: 60 → 68 → 68 passed。
- 41: **§9.13-V Phase A.2.3 closed with gap-surface outcome
  (no new fixtures)**. REPORT §10 item 1 (cross-instance v128
  import) 試みた fixture が wasm_instance_new で
  InstanceAllocFailed → 原因は **c_api evalConstExprValue が
  v128.const opcode (0xFD 0x0C) を reject** (Value=8 は v128
  slot を持たない構造的制約)。Fixture revert + **D-169 filed**
  blocked-by Phase A.3。REPORT §10 items 1/2/3 全て post-widen
  contract に整理 — Phase A.3 後に landing。Phase A.2 全体は
  cycles 39-41 (2 substantive + 1 gap-surface) で close、
  estimate 2-3 cycle 内。
- 42: **§9.13-V Phase A.3 — Value extern union widen 8→16
  landed on feature branch `zwasm-from-scratch-value16`**
  (226ce9d7)。`src/runtime/value.zig` に `bits128: u128` +
  `v128: [16]u8` variants 追加、`Value.zero` を `.bits128 = 0`
  に flip、`Value.fromV128` constructor 追加、in-source test
  も `@sizeOf == 16` + `@alignOf >= 16` + Value.zero v128 readback
  + fromV128 round-trip に拡充。Tree compile-green +
  lint-green;intentional runtime cascade red (SlotOverflow
  qLoadSpilled.spill abs_off=40 — Phase A.4c regalloc spill
  stride doubling の target)。Main (zwasm-from-scratch) は
  bcc4951f に stable。Phase A.4 cascade で green を restore
  予定。
- 43: **§9.13-V Phase A.4a — storage layouts (zero-init
  literals)** (e6ba1f5a)。2 sites の `.bits64 = 0` →
  `.bits128 = 0` 切り替え: `src/engine/setup.zig:187`
  (globals_buf @memset)、`src/api/instance.zig:905`
  (c_api function-call locals init for loop)。Other
  REPORT §2.a sites は "no source change" (auto-doubling
  via `[N]Value` / `[]Value` typed allocations)。Phase A.4a
  単独では runtime green を restore しない (regalloc /
  JIT codegen 残)。Compile + lint green。
- 44: **§9.13-V Phase A.4c — regalloc spill stride *8→*16**
  (269cb783)。`src/engine/codegen/shared/regalloc.zig` の
  `Allocation.slot` + `spillBytes` legacy fallback formula を
  `*8` から `*16` に switch。Test expectations bulk update。
  Mac `zig build test` GREEN (1760/1760)。SlotOverflow 解消。
- 45: **§9.13-V Phase A.4b — globals layout uniform 16-byte
  stride** (36c50710)。`src/engine/export_lookup.zig`
  computeGlobalsLayout の per-valtype 8/16 sizing を uniform 16
  に collapse — c_api `[*]Value` stride と spec-runner byte buffer
  を converge。`src/engine/codegen/{arm64,x86_64}/op_globals.zig`
  fallback `idx*8 → idx*16`。Test expectations 2 sites flip
  (arm64 STR W to [X23+16]; x86_64 MOV [RAX+16])。**Mac
  `zig build test-all` GREEN under Value=16**: edge 68/0,
  wast 72/0, spec_assert 212/0, wast_runtime 266/0。Phase A.4
  cascade restoration COMPLETE in 3 cycle (estimate 3.5-5);
  A.4f/A.4g re-classified as post-green cleanup ではなく
  cascade-blocker。
- 46: **§9.13-V Phase A.4f — D-169 discharged** (092d2cdb)。
  `evalConstExprValue` に `0xFD 0x0C` (v128.const) arm 追加。
  c_api wasm_instance_new が v128 globals module で
  InstanceAllocFailed しなくなった。D-170 filed (cross-module
  v128 globals JIT wiring 未 reconciled)。Mac test-all 維持 green。
- 47: **§9.13-V Phase A.4g-1 — evalConstScalarRawCtx
  slot_size cleanup** (4178e717)。REPORT §2.g item g.2:
  `runner_validate.zig` の global.get N (0x23) arm から
  per-valtype slot_size switch (`.v128 => 16` arm が
  unreachable な dead code) を削除、v128 rejection を
  bounds check の前に reorder、scalar 8-byte read width を
  literal 化。1/26 sites cleaned。Mac test-all 維持 green。
- 48: **§9.13-V Phase A.4g-2 — globals_byte_size field
  removal** (5c6f91fe)。REPORT §2.g items g.10-g.13 +
  g.14-extension。`CompiledWasm.globals_byte_size` +
  `GlobalsLayout.byte_size` field 削除 (uniform 16-byte stride
  で `globals_valtypes.len * 16` から計算可能);
  `compile.zig` の 3 sites + `export_lookup.zig` の
  `alignForward` cleanup + `spec_assert_runner_base.zig:1145`
  allocator site を inline computation に switch。~5/26
  cumulative。Mac test-all 維持 green。
- 49: **§9.13-V Phase A.4g-3 — applyDefinedGlobalsInit
  bounds check unification** (1fd60829)。REPORT §2.g item g.21 +
  resolveFuncrefGlobals 隣接 site。
  `compile_init.zig::applyDefinedGlobalsInit` の per-valtype
  switch から bounds check (`off + 16` for v128, `off + 8`
  for scalars) を switch 外 unified guard (`off + 16`) へ hoist。
  resolveFuncrefGlobals も同様。Mac test-all 維持 green。
  cumulative ~8/26。
- 50: **§9.13-V Phase A.4g-4 — applyImportedGlobalsFromRegistered
  uniform 16-byte copy (R-new-8 highest-risk)** (8fe9d801)。
  REPORT §2.g item g.20。`spec_assert_runner_base.zig:1782-1880`
  の `width = if (vt == .v128) 16 else 8` switch を uniform 16
  に collapse、bounds check + memcpy 全部 16-byte。Behaviour-
  preservation: scalar values 低 8 byte に居住 + 高 8 byte は
  `@memset` の zero-init で 0 のまま、不変。R-new-8 dissolved。
  Mac test-all 維持 green。cumulative ~9/26。

## Remaining work

### Next-session cold-start MUST read first

1. **[`.dev/phase9_remaining_flow.md`](./phase9_remaining_flow.md)**
   — Phase 9 close → Phase 10 open 全体フロー (Phase A-F)。
   サイクル見積もり + parallelization + tests-stay-green
   invariant の運用詳細。最初に読むと全体像が掴める。
2. **[`.dev/decisions/0110_value_widen_to_16_byte.md`](./decisions/0110_value_widen_to_16_byte.md)**
   — Phase A の設計記録、Accepted。
3. **[`.dev/phase9_value_widen_plan.md`](./phase9_value_widen_plan.md)**
   — Phase A 実装計画 6 sub-phase。
4. **[`../docs/cw_v1_consumer_contracts.md`](../docs/cw_v1_consumer_contracts.md)**
   — CW v1 (ClojureWasmFromScratch) consumer feedback
   contracts。Phase A.4d / A.4f / A.5 + Phase F の各 gate
   item として埋め込み済み (★必須 3件 C-1/C-2/C-3 +
   answered Q1-Q6 + long-term L-1/L-2 + co-exist §5)。
   **Phase A 着手前に必読** — drift 発生で CW v1
   dogfooding 破壊。

### Autonomous-eligible (next session pick from here)

優先順 (... A.4g-3 49; A.4g-4 50 on feature branch;
**Phase A.4g-5 起点**):

1. **§9.13-V Phase A.4g-5 — incremental cope cleanup**
   (**NEXT**, ~1 cycle)。REPORT §2.g remaining items: GlobalsCtx
   struct + scratch_globals []u8 → []Value migration は test
   infra 全面書き換え (~15+ sites) で大規模; 既に green な状態
   を維持しつつ docstrings update + 小規模 simplification を先に
   landing。
2. **§9.13-V Phase A.5 — cope code grep verification** (~0.5
   cycle)。REPORT §6 grep verification: `globals_offsets` /
   `GlobalsCtx` / `globals_byte_size` の hit counts 確認;
   残 cope sites の inventory + net code delta measurement。
3. **§9.13-V Phase A.6 — 3-host verify + merge to main**
   (~1 cycle, partial user-gated for merge)。feature → main
   rebase merge + ubuntu/windowsmini reconcile + bench delta。
   GlobalsCtx struct + scratch_globals 残 cope の正式 removal は
   Phase A.5/A.6 までに完了 OR Phase 10 へ defer 判断。
3. **§9.13-V Phase A.3-A.6** — Value flip + cascade + merge
   (feature branch `zwasm-from-scratch-value16`; D-167
   wire-up を A.4 内 に統合)。Phase 4d/4e はほぼ空、Phase
   4g が long pole (REPORT §8 reference)。
4. **Phase B / C / D** — windowsmini reconcile + ADR closure
   + debt cohort verify。Phase A と並列実行可能 (詳細は flow
   doc §4)。

### Still user-gated

- **ADR-0109** Accept → D-075 re-scope + native Zig API
  rewrite (~6-8 cycles)。§9.13-V Phase 4f で facade Value
  section が simplify される (V128 separate 不要に)。
- **§9.13 hard gate** — ADR-0105 + ADR-0106 Track D collab
  review + Phase B `[x]` re-flip per `phase9_close_master.md`
  §5.3a Phase B。**§9.13-V 完了が §9.13 ゲートの前提**
  (ADR-0104 Revision 2026-05-24 で expansion)。


## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
**Current state**: autonomous-eligible (feature-branch
workflow active at `zwasm-from-scratch-value16`; tree is
intentionally runtime-red until Phase A.4 cascade restores
green; main `zwasm-from-scratch` stable at bcc4951f). `now`
debts: D-167 (folded into §9.13-V Phase A.4f) + **D-169**
(c_api v128 const init gap; discharged inside Phase A.4f).
**Mac `zig build test-all` is GREEN** under Value=16. Phase
A.4g progress: cycle 47 cleaned 1/26 sites (slot_size switch).
Next: Phase A.4g-2 (globals_byte_size field removal,
g.10-g.13)。**Ubuntu per-chunk gate SKIPPED on feature branch**;
gate re-asserted at A.6 merge.
**Step 1a override**: `phase9_close_master.md` reference
above triggers close-plan override per SKILL.md; Step 2
(ROADMAP §9 first `[ ]` lookup) is therefore informational
— actual next work is per flow doc + plan doc.

## See

- ADR-0104 (Phase 9 真スコープ), ADR-0107 (byte-buffer
  globals), ADR-0108 (CATALOG-EXEMPT tier).
- `private/spikes/d167-win64-multi-arg-wrapper/README.md`.
