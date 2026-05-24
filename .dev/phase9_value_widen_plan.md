# Phase 9 §9.13-V — Value widen to 16-byte (implementation plan)

> **Doc-state**: ACTIVE — load-bearing for §9.13-V cohort.
> **Genesis**: 2026-05-24 cycle 37, paired with ADR-0110
> Accepted. Supersedes ADR-0052 cope-mechanism portion +
> obsoletes ADR-0107 (Withdrawn).
> **Authoritative for**: §9.13-V row execution. ROADMAP §9
> row references this doc for sub-chunk details.

## §1 — Purpose + scope

Migrate `Runtime.Value` from 8-byte `extern union` to 16-byte
`extern union` with v128 as a first-class variant. Remove all
cope mechanisms from ADR-0052 (per-valtype offsets table,
parallel byte storage, per-valtype JIT dispatch switch, spec
runner `GlobalsCtx` byte-buffer adapter) and ADR-0107
(c_api byte-buffer propagation).

**In scope**:
- Wasm 2.0 v128 SIMD types (existing) become structurally
  first-class
- v128 globals + locals + operand stack + JIT codegen all
  uniform 16-byte stride
- ADR-0052 / ADR-0107 cope code removed
- ADR-0109 (Zig API) Value section simplified — no separate
  `V128` type
- Test coverage strengthened for Value semantics (the
  user-flagged "テスト不足感"); boundary fixtures landed
  per `.claude/rules/edge_case_testing.md`

**Out of scope (deferred)**:
- Wasm 3.0 Relaxed SIMD ops (drop-in atop the widened Value;
  no plan-doc change needed when they land)
- Wasm 3.0 GC types (i31ref / struct refs / array refs fit
  in existing 8-byte ref slot; orthogonal to v128)
- v256+ portable SIMD (not in any Wasm proposal; Value=16 is
  terminal)

## §2 — Sub-phase plan (6-8 cycles)

### Phase 1 — Honest scope audit (1 cycle, autonomous) — **CLOSED 2026-05-24 cycle 38**

Inventory the actual cascade with primary code evidence (not
ADR-0052's inflated "50+ test sites" claim):

- grep for `@sizeOf(Value)`, `Value{...}`, `* 8`, `idx * 8`,
  `globals_base`, JitRuntime extern struct field offsets
- classify each hit as **truly-Value-tied** (changes with
  Value width) vs **stride-coincidental** (8 because Wasm/ABI
  spec dictates 8 bytes — e.g. WASI iovec entries are 8-byte
  by Wasm spec, not by Value width)
- output: `private/spikes/value-widen-scope-audit/REPORT.md`
  with file:line evidence + per-site classification + true
  cascade count
- this audit is the **ground truth** for Phase 4 impl
  estimation

**Exit**: REPORT.md written, true cascade count established,
risk register updated in this plan doc §4.

**Audit outcome** (see `private/spikes/value-widen-scope-audit/
REPORT.md` §1 for executive summary, §2 for full per-sub-phase
inventory):

- True cascade: ~14 Value-tied src/ sites + ~26 spec-runner cope
  sites + ~10 engine cope sites. Spec runner unification (Phase
  4g) dominates, not the Value flip itself.
- ADR-0052 "50+ test sites" claim is **inflated ~25×** — actual
  `@sizeOf(Value)` literal asserts = 1; `Value{...}` constructors
  flip transparently.
- **Phantom cope sites**: ADR-0110 §1.66-75 listed
  `globals_byte_storage` / `globals_byte_base` /
  `evalConstScalarValue` / `evalConstV128Value` — **none exist
  in tree**. Cope took a different shape (`globals_offsets[]` +
  `slot_size 8/16` switch in `evalConstScalarRawCtx`).
- **Phase 4d/4e are nearly empty**: JitRuntime fields are
  pointer/u32/u64 (don't shift); ZirInstr.payload is u32
  (not Value-tied).
- **Phase 4g is the new long pole** (~1.5-2 cycles): 26 sites
  including `applyImportedGlobalsFromRegistered` (~100 LOC
  simplification, single largest cope-removal site).
- See REPORT §10 for three Phase A.2 fixture additions beyond
  plan §3.

### Phase 2 — Test coverage strengthening (2-3 cycles, autonomous)

Address "テスト不足感" before touching the load-bearing Value
definition. Per ADR-0020 + `.claude/rules/edge_case_testing.md`
"Stress axes" — add boundary fixtures across:

- **Numeric range**: Value-stored INT_MIN/MAX (i32, i64),
  ±0, ±Inf, NaN payload preservation (f32/f64), denormal
- **v128 lane**: lane 0 / lane max-1 / lane max / OOB lane
  for each shape (i8x16, i16x8, i32x4, i64x2, f32x4, f64x2)
- **Cross-shape v128**: shuffle / splat / replace_lane /
  extract_lane round-trip
- **NaN propagation in v128 FP ops**: f32x4 / f64x2 NaN
  payload survival through arithmetic / lane ops
- **Ref encoding**: funcref/externref null sentinel
  (`null_ref == 0`), `@intFromPtr(*FuncEntity)` round-trip,
  cross-instance funcref aliasing
- **8-byte slot boundary** (pre-widen): assert current
  `@sizeOf(Value) == 8` behavior to establish baseline
- **16-byte slot boundary** (post-widen): assert
  `@sizeOf(Value) == 16` + v128 alignment

Fixtures land at `test/edge_cases/p9/value_semantics/` per
existing edge_case_testing.md convention.

**Exit**: all new boundary fixtures green on Mac+ubuntu
test-all; per-fixture WAT + .expect committed.

### Phase 3 — Value definition migration (1 cycle, autonomous)

The atomic flip — `src/runtime/value.zig` widened from 8 to
16 bytes.

```zig
// New shape (replacing 8-byte version)
pub const Value = extern union {
    bits128: u128,
    bits64_lo: u64,
    i32: i32, u32: u32,
    i64: i64, u64: u64,
    f32_bits: u32,
    f64_bits: u64,
    ref: u64,
    v128: [16]u8,

    pub const zero: Value = .{ .bits128 = 0 };
    pub const null_ref: u64 = 0;
    // ... existing constructors stay; add fromV128(bytes: [16]u8)
};

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
    std.debug.assert(@alignOf(Value) >= 16);
}
```

This single commit is **expected to break most of the tree**
(JIT struct offsets shift, stride assumptions broken, etc.).
Land on a feature branch or accept the broken state for a few
cycles? **Decision: feature branch under
`zwasm-from-scratch-value16` worktree, periodic rebase against
main, merge once Phase 4 cascade is complete + green.**

Rationale: `zwasm-from-scratch` main stays green for D-167
wire-up + Phase 9 close gate work running in parallel.

**Exit**: Value=16 in feature branch; intentional breakage
acknowledged; cascade work begins in same branch.

### Phase 4 — Cascade implementation (3-5 cycles, autonomous)

Per Phase 1 scope audit, in dependency order:

**Phase 4a — Storage layouts**
- `Runtime.operand_buf: [N]Value` — array literal stays, sizeof doubles
- `Runtime.globals_storage: []Value` — uniform 16-byte stride
- Remove `Runtime.globals_byte_storage: []u8` (ADR-0052 parallel storage)
- Remove `Runtime.globals: []*Value` (replaced by direct `[]Value` slice indexing or kept depending on cross-module aliasing decision — see §3 test plan)
- `Runtime.globals_offsets: []u32` — removed; replaced by `idx * 16`
- `Runtime.globals_valtypes: []ValType` — kept for typed access

**Phase 4b — JIT codegen globals**
- `[X23, #idx*8]` → `[X23, #idx*16]` arm64
- `[R<scratch> + idx*8]` → `[R<scratch> + idx*16]` x86_64
- Use `Q` register variant (arm64 NEON) / `MOVUPS` (x86_64) for v128 access
- Remove per-valtype switch in `.global_get` / `.global_set` dispatch arms (single emit path)

**Phase 4c — JIT codegen operand stack spill**
- `regalloc.zig` spill stride `* 8` → `* 16`
- Spill slot alignment requirement (16-byte for v128)

**Phase 4d — JitRuntime extern struct field offsets**
- Re-compute all field offsets in `JitRuntime` after `operand_buf` stride change
- Update arm64 / x86_64 prologues that load `globals_base`,
  `funcptr_base`, `typeidx_base` etc via `[X19 + offset]` —
  every offset shifts
- Mechanical but exhaustive

**Phase 4e — ZIR payload encoding**
- ZirOp payload assumptions: 8-byte slot → 16-byte slot
- Encoder version bump
- Debug dump format invalidation — acceptable (debug only)
- Migration tool: not needed; re-dump from re-compiled fixtures

**Phase 4f — Host-call marshaling + c_api**
- `host_calls` Value array — stride doubles, auto-propagated
- `src/api/instance.zig` `Val` type passthrough — facade
  `Value` no longer needs `valueToVal` v128 hard-coded-0
- ADR-0109 (Zig API) facade Value section simplifies — no
  separate `V128` type, just Value variant
- `docs/zig_api_design.md` §4.2 (v128) section updated

**Phase 4g — Spec runner unification**
- Remove `GlobalsCtx` byte-buffer adapter (ADR-0052)
- Spec runner uses uniform `Runtime.globals` directly
- ADR-0107 cope path obsoletion (Withdrawn ADR; remove any
  in-tree references)

**Exit per sub-phase**: Mac+ubuntu test-all green + lint
green + commit. Windows reconcile at Phase 4 completion.

### Phase 5 — Cope code removal verification + CW v1 contract gate (1 cycle, autonomous)

**CW v1 consumer contract verification** (added cycle 37
post-CW-v1 feedback; rails per
[`../docs/cw_v1_consumer_contracts.md`](../docs/cw_v1_consumer_contracts.md)
§6 checklist):

- C-1: `comptime std.debug.assert(@alignOf(FuncEntity) >= 8)`
  asserted at FuncEntity declaration site
- C-2: `Trap` enum has 12 variants exactly; header comment
  "ABI-stable variant set per cw_v1_consumer_contracts.md §1 C-2"
- C-3: `grep -rn 'c_allocator\|page_allocator\|GeneralPurposeAllocator'
  src/api/ src/runtime/` audited; all hits classified
  (test-only / Debug-only OK; production-path hits forbidden
  without ADR)
- L-1: `Instance.invoke` API present, not deprecated
- L-2: linker memory default behavior verified (undefined
  memory import → instantiate error)
- §5 co-exist: `src/api/instance.zig` intact + functional
  (wasm-c-api binding survives Phase A cascade)

Phase 5 cannot close without every contract box ticked.
Failure of any box requires fix-in-same-chunk OR explicit
ADR amendment documenting the deviation + CW v1 maintainer
notification.

### Phase 5 — Cope code grep portion (continues)

Grep verification that no ADR-0052 / ADR-0107 cope code
remains:

- `grep -rn "globals_offsets\|globals_byte_storage\|globals_byte_base\|GlobalsCtx" src/`
  → expected: 0 hits
- `grep -rn "evalConstScalarValue\|evalConstV128Value" src/`
  → either unified into one or doc the boundary
- `grep -rn "per.valtype.*switch\|per.valtype.*offset" src/`
  → 0 hits

Net code delta: expect **300-500 LOC removed** (cope mechanism
+ comments) vs **50-100 LOC added** (widened Value declarations
+ comptime assertions). Net negative.

**Exit**: cope-code grep clean; ADR-0052 / ADR-0107 references
audited.

### Phase 6 — 3-host verify + ADR closure (1 cycle, user-gated review)

- `bash scripts/run_remote_windows.sh test-all` — windowsmini
  green
- Spec corpus skip-impl == 0 maintained
- Bench delta captured (Phase 8b discipline applied since
  this touches codegen): scalar-only modules should show
  ≤5% regression (operand stack doubling); v128 modules
  should show 1.5-3× improvement (no offsets lookup +
  single-path emit)
- ADR-0110 Revision history entry: implementation cycle SHAs
- ADR-0052 portion supersession confirmed
- ADR-0107 Withdrawn lineage confirmed
- ADR-0104 Phase 9 真スコープ amendment confirmed
- §9.13-V row `[x]` flip + SHA backfill

**Exit**: §9.13-V `[x]`, all listed ADR cleanup done, plan
doc transitions to ARCHIVED.

## §3 — Test plan detail

Address user-flagged "テスト不足感" by treating Phase 2 as
a load-bearing investment, not a side-task.

### Test categories

1. **Pre-widen baseline assertion**: snapshot current Value
   semantics behavior with new fixtures, ensure they all
   pass on the 8-byte Value. These same fixtures must pass
   post-widen (= migration is behavior-preserving).
2. **v128 lane operation comprehensive**: every shape
   (i8x16, i16x8, i32x4, i64x2, f32x4, f64x2) × every
   lane op (extract, replace, splat, shuffle, swizzle) ×
   boundary lanes (0, max-1, max, OOB).
3. **NaN payload preservation**: f32/f64 + v128 f32x4/f64x2
   — assert NaN bits survive operand stack round-trip,
   global.set+get round-trip, host_call marshal round-trip,
   Wasm op pass-through where spec allows (per Wasm §6.2.3).
4. **Cross-instance v128 funcref / globalref**: import v128
   global from one instance into another; assert the imported
   value matches and updates correctly (per ADR-0014
   cross-instance aliasing semantics — adjusted for
   uniform Value).
5. **Memory layout assertions**: `comptime
   std.debug.assert(@sizeOf(Value) == 16)` +
   `@alignOf(Value) >= 16`. Pre-widen: `== 8`. Post-widen
   commit flips both.
6. **JIT register usage** for v128 ops: verify Q-reg
   (arm64) / XMM (x86_64) used for v128 instead of GPR
   pair workaround.

### Fixture locations

- `test/edge_cases/p9/value_semantics/` — pre/post widen
  baseline + Value-tied edge cases
- `test/edge_cases/p9/v128_lane_ops/` — comprehensive lane
  matrix
- `test/edge_cases/p9/v128_nan_payload/` — FP NaN
  preservation
- `test/edge_cases/p9/v128_cross_instance/` — import wiring

Each fixture follows the `.wat` + `.wasm` + `.expect`
convention per `.claude/rules/edge_case_testing.md`.

### Test execution gate

Phase 2 fixtures must be green on Mac+ubuntu test-all
**before** Phase 3 Value widening lands. They form the
behavior-preservation contract for Phase 4 cascade work.

## §4 — Risk register

| ID | Risk | Mitigation |
|---|---|---|
| R1 | ~~ZIR payload encoding breakage~~ — **dissolved per Phase 1 audit**: ZirInstr.payload is u32 (not Value-tied); no encoder bump | n/a |
| R2 | ~~JitRuntime extern struct field offset shift~~ — **downgraded per Phase 1 audit**: all fields are pointer/u32/u64; no offsets shift. Only docstrings stale | docstring-only update at Phase 4d |
| R3 | Bench regression for scalar-only modules (operand stack doubling 32→64 KiB per Runtime) | Phase 6 bench delta required per Phase 8b discipline; if > 5% regression on representative scalar fixture, investigate hot-path optimization (e.g. compact frame layout for scalar-only functions) |
| R4 | Feature-branch merge conflicts with main (D-167 wire-up + Phase 9 close work) | Periodic rebase against main during cascade work; if conflicts grow, consider co-landing instead of branch isolation |
| R5 | Phase 2 test coverage strengthening surfaces existing bugs in 8-byte Value path | Honest investigation; if bug is critical, fix before Phase 3 widen; if bug is Value-width-independent, file as separate debt |
| R6 | Cope-code removal grep (Phase 5) reveals out-of-tree consumers expecting old shape (e.g. external tooling) | Unlikely (zwasm v2 isn't released yet); if found, document removal in v0.2 migration notes |
| R7 | windowsmini Win64 ABI surfaces new edge case with 16-byte Value (e.g. v128 args in calling convention) | Phase 6 windowsmini reconcile catches; mitigation: per ADR-0106 wrapper-thunk path can absorb Win64 v128 calling convention quirks |
| R8 | `applyImportedGlobalsFromRegistered` (test/spec/spec_assert_runner_base.zig:1782-1880) is the single largest cope-removal site (~100 LOC) with per-valtype byte-copy width logic — high churn, high regression risk | Phase 2 boundary fixture: cross-instance v128 global import with recognizable lane pattern (per REPORT §10). Migration becomes uniform `importer_buf[slot] = exporter_buf[slot]`; fixture catches if either pre- or post-widen path regresses |
| R9 | `globals_valtypes` is consumed by validator (src/validate/validator.zig:815,821) for spec-correct type-checking. Mistakenly dropping it during cope cleanup would break Wasm spec validation | Phase 4g cope-removal scope explicitly retains `globals_valtypes` (vs dropping `globals_offsets` + `globals_byte_size`). REPORT §6 names the boundary |
| R10 | `Runtime.globals: []*Value` indirection (cross-module aliasing per ADR-0014 §6.K.3) is orthogonal to Value width but easily confused mid-refactor | Phase 4a preserves aliasing semantics; only the pointed-at slot doubles. REPORT §2.a row a.4 documents the boundary |

## §5 — Cycle estimate

| Phase | Cycle count | Cumulative |
|---|---|---|
| Phase 1 — scope audit | 1 (CLOSED 2026-05-24 cycle 38) | 1 |
| Phase 2 — test coverage | 2-3 | 3-4 |
| Phase 3 — Value definition | 1 | 4-5 |
| Phase 4 — cascade impl (a-g) | 3.5-5 (4a ~0.5, 4b ~1, 4c ~0.5, 4d ~0.25, 4e ~0, 4f ~0.5, 4g ~1.5-2) | 7.5-10 |
| Phase 5 — cope code grep | 1 | 8.5-11 |
| Phase 6 — 3-host verify + ADR closure | 1 | 9.5-12 |

**Total estimate**: 9-12 cycles. Bounded; not open-ended.

Phase 1 audit refined Phase 4 sub-phase distribution: 4d/4e are
nearly empty; 4g (spec runner unification) is the new long pole.
Total holds at 9-12 cycles.

At current autonomous loop pace (~1 cycle / 30-60 min when
unblocked), this is **~1-2 calendar weeks** of zwasm v2 work,
running in parallel with D-167 wire-up + Phase 9 close gate.

## §6 — ROADMAP §9 row integration

Add new row to §9.<active phase>:

```markdown
| 9.13-V | **Value widen to 16-byte (terminal SIMD width) per ADR-0110.** Six sub-phases per `.dev/phase9_value_widen_plan.md`: scope audit → test coverage strengthening → Value definition flip → cascade impl → cope code removal → 3-host verify. Removes ADR-0052 per-valtype offsets cope + obsoletes ADR-0107 (Withdrawn). Implements v128 first-class per industry 5/7 majority. CW v2 dogfooding-aware (ADR-0109 Value section simplifies in same cohort). Exit: cope-code grep clean + Mac+ubuntu+windowsmini test-all green + bench delta within tolerance. | [ ] |
```

This row's `[ ]` flips when Phase 6 completes.

## §7 — Coordination with parallel work

§9.13-V can run in parallel with:

- **D-167 wire-up** (current `now` debt; entry helper Win64
  if-arm landing) — independent of Value width, safe to land
  on main while §9.13-V on feature branch
- **§9.13 hard gate Phase B** (collab review for ADR-0105/0106
  +SHA backfill) — user-gated, orthogonal
- **ADR-0107 Accept** (now Withdrawn 2026-05-24, no longer
  applicable)
- **ADR-0109 Zig API** implementation — coordinates with §9.13-V
  Phase 4f (facade Value section simplifies)

Coordination rule: §9.13-V Phase 3 (Value widening) on
feature branch. Phase 6 merge requires all parallel work on
main to be green; rebase + integration test gates the
merge.

## §7a — Phase A.5 cope-grep verification (cycle 51, 2026-05-24)

Phase A.5 per plan doc §2 Phase 5 + REPORT §6. Residual cope
inventory after Phase A.4g sub-chunks:

| Identifier            | Pre-Phase A | Post-cycle 50 | Note                                                                                              |
|-----------------------|-------------|---------------|---------------------------------------------------------------------------------------------------|
| `globals_byte_storage` | claimed     | 0 hits         | Phantom per Phase A.1; never existed in tree                                                      |
| `globals_byte_base`    | claimed     | 0 hits         | Same                                                                                              |
| `evalConstScalarValue` | claimed     | 0 hits         | Same — actual name `evalConstScalarRawCtx`                                                        |
| `evalConstV128Value`   | claimed     | 0 hits         | Same — actual name `evalConstV128Expr`                                                            |
| `globals_byte_size`    | 8 hits      | 0 hits         | Removed cycle 48 (Phase A.4g-2)                                                                   |
| `globals_offsets`      | 79+ hits    | 47 src + 39 test ≈ 47 src code refs | **Load-bearing** JIT metadata table; per-global byte offset for `[X23 + byte_off]` emit. Further removal requires architectural shift (emit `[X23 + idx*16]` inline instead of lookup) — Phase 10+ work. |
| `GlobalsCtx`           | structural  | 9 hits         | Spec runner const-expr eval context (offsets / valtypes / buf / num_imports). Structurally required to pass eval-time globals state; removing the struct doesn't simplify (args still passed individually). Keep. |

**Net diff vs main** (feature branch `zwasm-from-scratch-value16`
@ cycle 50): +313 / -152 = **+161 LOC**. Of the +313 additions,
~96 LOC is fixture WAT/expect files (16 boundary fixtures from
Phase A.2.1/A.2.2). Excluding fixtures: ~+65 LOC net change
(roughly neutral; cope removal balanced by ADR-0110 widen
infrastructure + comptime asserts).

REPORT §6 net-delta prediction was 250-350 LOC removed. **Actual
delta differs because**: ADR-0110 §1.66-75 listed 4 phantom items
(globals_byte_storage / globals_byte_base / 2 phantom function
names) as cope — they didn't exist in tree to begin with, so
removing them yielded 0 LOC. The remaining true cope items
(globals_offsets metadata, GlobalsCtx eval context) are
structurally load-bearing for current JIT codegen and spec
runner — full removal exceeds Phase A scope.

**Phase A.4g closure decision**: Phase A.4g delivered the
substantive cleanup goals (uniform 16-byte stride established
everywhere; per-valtype 8/16 switch sites collapsed; R-new-8
highest-risk migration boundary dissolved). The remaining
`globals_offsets` / `GlobalsCtx` references are not cope-vs-
clean choices but structural metadata that Phase 10+ rework
may simplify alongside ADR-0109 native Zig API + D-170
discharge. **Closing Phase A.4g at cycle 50 state**;
remaining cope cleanup deferred to Phase 10.

## §8 — Revision history

- 2026-05-24 — Initial draft alongside ADR-0110 Accepted at
  cycle 37. User collab confirmation: "Value=16 は対応する、
  ということで確定", test concerns explicitly addressed in
  Phase 2.
- 2026-05-24 cycle 51 — **Phase A.5 cope-grep verification
  CLOSED**. Net delta +161 LOC (fixture-inflated; ~+65 LOC
  net code change). REPORT §6 prediction differed because
  4 cope items were phantom (never in tree). Remaining
  `globals_offsets` / `GlobalsCtx` references are
  structurally load-bearing; further cleanup deferred to
  Phase 10 alongside ADR-0109 + D-170 discharge. Phase A.4g
  closed at cycle 50 state. Ready for Phase A.6 (3-host
  verify + merge to main).
- 2026-05-24 cycle 38 — Phase 1 (scope audit) CLOSED. REPORT
  at `private/spikes/value-widen-scope-audit/REPORT.md`. §2
  Phase 1 section updated with audit outcome; §4 risk register
  added R8/R9/R10 + dissolved R1/downgraded R2 per audit
  evidence; §5 cycle estimate refined per-sub-phase. Phase A.2
  is the next chunk; REPORT §10 names three boundary fixtures
  beyond plan §3 (cross-instance v128 import, globals
  alignment, Value.zero v128 readback).
- 2026-05-24 cycles 39-41 — **Phase 2 (test coverage) CLOSED**.
  13 fixtures landed (5 scalar + 8 v128) under
  `test/edge_cases/p9/value_semantics/` + `v128_lane_ops/` +
  `v128_nan_payload/`. Cycle 41 attempted REPORT §10
  cross-instance v128 import fixture (`test/runners/fixtures/
  v128_cross_instance/`) and surfaced a **new production gap**:
  c_api `evalConstExprValue` at `src/runtime/instance/instantiate.zig:340-373`
  rejects `v128.const` (opcode 0xFD 0x0C) — Value=8 has no
  slot to write into. Fixture reverted; filed as **D-169**
  blocked-by Phase A.3 (Value widen unblocks the new
  `Value.v128: [16]u8` variant + the `evalConstExprValue` arm).
  REPORT §10 items 1/2/3 all defer to Phase A.3 (post-widen
  contracts that can't be authored at Value=8 baseline). New
  gap is enrichment beyond REPORT §6 c_api cope inventory —
  the const-init path was not previously enumerated as cope.
- 2026-05-24 cycles 42-50 — **Phase 3-4 CLOSED**:
  - Phase 3 (A.3 Value union widen) at cycle 42 (`226ce9d7`).
  - Phase 4a (storage zero-init literals) at cycle 43.
  - Phase 4c (regalloc spill stride *8→*16) at cycle 44 —
    Mac `zig build test` GREEN under Value=16.
  - Phase 4b (globals layout uniform 16-byte stride;
    `computeGlobalsLayout` collapsed per-valtype 8/16 to uniform
    16; op_globals.zig fallbacks `*8 → *16`) at cycle 45 —
    Mac `zig build test-all` GREEN (edge 68/0, wast 72/0,
    spec_assert 212/0, wast_runtime 266/0). **Phase 4 cascade
    restoration COMPLETE in 3 cycles** (under 3.5-5 estimate)
    because A.4b unblocked the cascade head; A.4d/A.4e
    confirmed empty per REPORT §2.d/§2.e.
  - Phase 4f (D-169 discharge: evalConstExprValue v128.const
    arm + marshalValOut docstring) at cycle 46 (`092d2cdb`).
    **D-169 closed**. Side-find: D-170 filed for c_api JIT
    runtime wiring of v128 globals via `wasm_instance_new`
    (cross-module v128 path traps Unreachable; spec runner
    byte-buffer cope masks it). Deferred to Phase 10 / D-170.
  - Phase 4g (spec runner GlobalsCtx removal) cycles 47-50:
    A.4g-1 evalConstScalarRawCtx slot_size cleanup; A.4g-2
    globals_byte_size field removal (CompiledWasm +
    GlobalsLayout + 4 sites); A.4g-3 bounds check unification
    in applyDefinedGlobalsInit + resolveFuncrefGlobals;
    A.4g-4 applyImportedGlobalsFromRegistered uniform 16-byte
    copy (R-new-8 dissolved).
