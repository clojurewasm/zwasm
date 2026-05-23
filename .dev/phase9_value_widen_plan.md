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

### Phase 1 — Honest scope audit (1 cycle, autonomous)

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
| R1 | ZIR payload encoding breakage invalidates cached `.zir` debug dumps | Acceptable (debug only); re-dump from re-compiled fixtures; document in commit body |
| R2 | JitRuntime extern struct field offset shift cascades through all per-arch prologues | Phase 1 audit identifies all sites; Phase 4d landed atomically per arch; per-arch test-all gates each landing |
| R3 | Bench regression for scalar-only modules (operand stack doubling) | Phase 6 bench delta required per Phase 8b discipline; if > 5% regression on representative scalar fixture, investigate hot-path optimization (e.g. compact frame layout for scalar-only functions) |
| R4 | Feature-branch merge conflicts with main (D-167 wire-up + Phase 9 close work) | Periodic rebase against main during cascade work; if conflicts grow, consider co-landing instead of branch isolation |
| R5 | Phase 2 test coverage strengthening surfaces existing bugs in 8-byte Value path | Honest investigation; if bug is critical, fix before Phase 3 widen; if bug is Value-width-independent, file as separate debt |
| R6 | Cope-code removal grep (Phase 5) reveals out-of-tree consumers expecting old shape (e.g. external tooling) | Unlikely (zwasm v2 isn't released yet); if found, document removal in v0.2 migration notes |
| R7 | windowsmini Win64 ABI surfaces new edge case with 16-byte Value (e.g. v128 args in calling convention) | Phase 6 windowsmini reconcile catches; mitigation: per ADR-0106 wrapper-thunk path can absorb Win64 v128 calling convention quirks |

## §5 — Cycle estimate

| Phase | Cycle count | Cumulative |
|---|---|---|
| Phase 1 — scope audit | 1 | 1 |
| Phase 2 — test coverage | 2-3 | 3-4 |
| Phase 3 — Value definition | 1 | 4-5 |
| Phase 4 — cascade impl (a-g) | 3-5 | 7-10 |
| Phase 5 — cope code grep | 1 | 8-11 |
| Phase 6 — 3-host verify + ADR closure | 1 | 9-12 |

**Total estimate**: 9-12 cycles. Bounded; not open-ended.

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

## §8 — Revision history

- 2026-05-24 — Initial draft alongside ADR-0110 Accepted at
  cycle 37. User collab confirmation: "Value=16 は対応する、
  ということで確定", test concerns explicitly addressed in
  Phase 2.
