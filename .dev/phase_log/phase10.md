# Phase 10 execution log

> **Doc-state**: ACTIVE

> Sub-chunk records for Phase 10 (Wasm 3.0 — GC, EH, Tail Call,
> memory64) absorbed from `.dev/ROADMAP.md` §10 task table per
> §18.3 (ROADMAP rows stay now-snapshots; per-sub-chunk prose
> lives here). Authoritative history is `git log` — this file
> is a readable grouping by row. Mirrors `phase9.md` shape.
>
> Phase 10 opened 2026-05-24 (Phase 9 = DONE, §9.13 hard gate
> cleared at `36c494a3`; widget 9→DONE; §10 inline expanded
> with 11 sub-rows 10.C9 / 10.F / 10.Z / 10.D / 10.T / 10.M /
> 10.R / 10.TC / 10.E / 10.G / 10.P).
>
> Authoritative design source:
> [`phase10_design_plan_ja.md`](../phase10_design_plan_ja.md)
> §3-§8 (r3; 2026-05-24 user-reviewed; サブシステム別実装方針
> / テスト戦略 / 7 ADR / 23 invariants).


## Row 10.C9 — Phase 9 close 後始末

**Scope**: §9.11 audit_scaffolding Phase-boundary pass + §9.x
17-row SHA backfill + bench Phase 9 close baseline →
`bench/results/history.yaml` + `phase9_close_master.md`
Doc-state → ARCHIVED-IN-PLACE + `phase_log/phase10.md` 作成.

**Status**: [ ] (5 sub-steps in progress; flips [x] at step 5
close)

### Sub-chunks (commit-time order)

- **10.C9-step1** — §9.11 audit_scaffolding Phase-boundary
  pass; `private/audit-2026-05-24-phase9-close.md` 生成
  (0 block / 4 soon / 6 watch); extended-challenge anchors
  全て OK (windowsmini zig/wasmtime, ubuntunote nix/sudo) `[x]`
- **10.C9-step2** — §9.x SHA backfill 23 rows (9.0..9.13);
  9.12-I を `c5ec6889` / 9.13-0 を `add3da3d` (ADR-0104
  reframe 後 canonical close commits) に修正 `[x] 1433004b`
- **10.C9-step3** — bench Phase 9 close baseline; 14 fixture
  Mac aarch64 ReleaseSafe; `bench/results/history.yaml` line
  313526 に reason="p9-close: Wasm-2.0 baseline (Mac aarch64)"
  append; Phase 10 計測のゼロ点 (ADR-0012 §7) `[x] e861143c`
- **10.C9-step4** — phase9_close_master.md Doc-state ACTIVE →
  ARCHIVED-IN-PLACE 2026-05-25 + `check_phase9_close_invariants
  .sh` I7 regex を `(ACTIVE|ARCHIVED-IN-PLACE)` に拡張 +
  `.claude/rules/phase9_close_invariants.md` 冒頭に Retirement
  status 段落追加 — bundle 1 commit; 18/18 invariants 維持 `[x] 91059738`
- **10.C9-step5** — `phase_log/phase10.md` 新規ファイル作成
  (sub-chunk 記録先; mirrors phase9.md shape) `[x]` (this commit)


## Row 10.Z — ZirInstr 128-bit 拡張 (`payload: u32 → u64`)

**Scope**: ROADMAP §10 row 10.Z — widen `ZirInstr.payload`
(`src/ir/zir.zig:73`) for memory64 offset carry per design plan
§3.1 / Z.1。

**Status**: `[x]` (cycle-2 succeeded; 2/3 attempts used)。

### Sub-chunks (commit-time order)

- **10.Z-cycle1** — Mechanical widen attempt; 131 compile errors
  observed (120× `expected u32 found u64` + 11× @bitCast size
  mismatch). Reverted per ROADMAP "失敗時 chunk revert"。`.dev/
  phase10_z_chunk_plan.md` 新規で cycle-2 subagent strategy 文書化。
  Architectural-chunk attempt 1/3.
- **10.Z-cycle2** — Subagent-driven mechanical migration per
  `.dev/phase10_z_chunk_plan.md` §"Cycle-2 strategy" `[x] 7fb6593d`
  (30 files modified: IR substrate + memory ops helper signature
  widen + arm64/x86_64 codegen `@intCast` at consumer + i32.const
  `@truncate` narrow + parser/dispatch test-fixture explicit
  `@as(u32, ...)` cast at payload assignment. Mac `zig build
  test-all` GREEN 1773/1787, substrate `test` 1827/1841, lint
  clean, I3 18/18. emit_test_*.zig byte-identical maintained.
  ROADMAP §10 / 10.Z `[x]` flipped.)


## Row 10.F — c_api scalar accessors

**Scope**: wasm-c-api spec 標準 global / table / memory
accessors を `src/api/instance.zig` に追加 (D-171 / D-172 /
D-173; `phase9_close_master.md` §5.3a Phase F)。

**Status**: `[x]` (10.F-a/b/c all closed; D-171 / D-172 / D-173 all
discharged in `.dev/debt.md`; D-178 new debt opened for v0.2
host-side `wasm_global_new`).

### Sub-chunks (commit-time order)

- **10.F-D171-mv** — D-171 minimum-viable global accessors
  (export-derived path). `Global` opaque handle + `wasm_extern
  _as_global` + `wasm_global_get/set/delete` を追加; mutable
  i32 global in-source test green; Mac test-all green; v128
  permanently spec-prohibited per `2026-05-24-c_api-v128-spec
  -boundary.md` `[x] 142502a5`
- **10.F-D171-full** — `wasm_global_new` + `wasm_globaltype_new` +
  `wasm_valtype_new` (host-side standalone construction; Extern
  wrap → `wasm_instance_new(imports[])` シナリオ用) DEFERRED to
  v0.2 follow-up; tracked as new debt D-178. The audit's A1
  requirement is already satisfied by the MV `142502a5`
  (export-derived path); standalone construction is orthogonal.
- **10.F-c** — `wasm_table_grow` (deferred from 10.F-b) +
  10.F close `[x] 3889661b` (Wasm spec §4.4.6 table.grow:
  realloc-extend `rt.tables[idx].refs` + init-fill +
  declared-max enforcement; Tier-1 test "wasm 2.0 c_api
  wasm_table_grow: grow + init-fill + max-limit" PASS; D-171
  formally closed with D-178 deferral note; D-172 + D-173 already
  in discharged section; ROADMAP §10 / 10.F `[x]` flipped.)
- **10.F-D172** — `wasm_extern_as_table` + `wasm_table_get/
  set/size` + minimal `wasm_ref_t` + `wasm_ref_delete` `[x] cf6f009e`
  (pub const Table + pub const Ref + 6 c_api exports per
  include/wasm.h:466-477 + 327-365; Tier-1 "wasm 2.0 c_api table
  accessors: size + get + set round-trip (D-172)" PASS; B1 audit
  gap (cross-instance table.set aliasing) unblocked;
  `wasm_table_grow` deferred to next sub-chunk. File-size exempt
  cap 2800→3000 via ADR-0099 (cap=N) override.)
- **10.F-D173** — `wasm_extern_as_memory` + `wasm_memory_data
  /data_size/size/grow` + `wasm_memory_grow` `[x] 7a8c3ae2`
  (pub const Memory + 5 c_api exports per include/wasm.h:471-481;
  Tier-1 "wasm 2.0 c_api memory accessors: data + size + grow
  round-trip (D-173)" PASS; B2 audit gap (cross-instance
  memory.copy aliasing) unblocked; D-173 discharged. File-size
  exempt cap 2500→2800 via ADR-0099 (cap=N) override.)


## Row 10.J — Native Zig API (ADR-0109)

**Scope**: `src/zwasm.zig` rewrite per `docs/zig_api_design.md`
(Engine + Linker + TypedFunc + Memory slice view + Caller ctx +
full Trap error set + allocator strict-pass)。Internal rename
`runtime.Runtime` → `runtime.JitRuntime` lands first
(mechanical; ABI-preserving)。

**Status**: [ ] (J.0 amend round in progress this commit;
J.1+ gated on execution plan doc)

### Sub-chunks (commit-time order)

- **10.J-0** — ADR-0109 Status: Proposed → Accepted; ADR-0025
  Status: Superseded; `docs/zig_api_design.md` §4 reconciled
  with ADR-0110 (16-byte Value); D-075 re-scoped to impl
  tracker; ROADMAP §10 new row 10.J inserted before 10.F;
  phase9_close_master.md / phase9_remaining_flow.md /
  phase9_value_widen_plan.md Doc-state updated;
  phase10_design_plan_ja.md §7 work-sequence + §3.x
  ADR-0109 sub-section added; handover.md refresh `[ ]` (this commit)
- **10.J-invest** — pre-impl investigation + execution plan +
  integrated test strategy. 2 subagents (Explore, parallel)
  produced `private/notes/p10-J.invest-code-survey.md` (990
  lines; site-by-site change enumeration, rename impact 25+
  files, TypedFunc comptime feasibility analysis, layering
  recommendations) + `private/notes/p10-J.invest-test-survey
  .md` (579 lines; fixture inventory 57 realworld + ~100 edge-
  case, ADR-0109 §3 pattern decomposition, three-tier
  architecture proposal, 5 must-have scenarios). Plan doc
  synthesizes both into [`phase10_zig_api_plan.md`](../phase10
  _zig_api_plan.md) — 8 impl chunks (J.1..J.close) + integrated
  test strategy + 7 decision points + 10 risk items. **User
  review gate**: J.1 first commit blocked until plan reviewed `[x]` (this commit)
- **10.J-1+** — implementation cycles per plan doc §3 (J.1
  withdrawn 2026-05-25; Engine + Module + allocator strict-pass
  → Instance + Trap full set → TypedFunc + Memory + multi-result
  → Linker + Caller + host imports → Tier-2 runner → WASI
  skeleton → close + coverage audit) (~6-10 cycles per plan §7
  post-J.1 retraction)
- **10.J / J.2** — `src/zwasm/{engine,module}.zig` new; c_api
  `Runtime` + `Module` veneers in `src/zwasm.zig` deleted; `Instance`
  field `rt: *Runtime` → `c_store: *_api_instance.Store` (rt was
  unused by `invoke`). Native parser path via `src/parse/parser.zig`
  with allocator threaded. T1.1 (RecordingAllocator strict-pass) +
  T1.2 (truncated header / bad magic → `error.ParseFailed`) + the
  existing round-trip test rewritten on Engine. I3 grep updated
  `pub const Runtime` → `pub const Engine`. zone_check classifier
  extended `src/zwasm/*` → `lib`. Mac 1812/1826 PASS, I3 18/18,
  ubuntu kicked post-push (`017193bc`)
- **10.J / J.close** — Docs-only close of 10.J. ROADMAP §10 row
  10.J flipped `[ ]` → `[x]`. ADR-0109 Revision history row added
  ("Implementation complete; 6 cycles J.2..J.7 SHAs cited; Status
  remains Accepted pending cw v1 dogfooding per Removal condition").
  Plan §3 J.close row marked CLOSED + §4.2 coverage matrix audit
  result appended ("every shipped public symbol carries ≥ 1 Tier-1
  test; `defineGlobal` / `defineTable` / `Instance.global` /
  `.table` / `Instance.call` sugar / `engine.linker()` factory /
  `Module.exports().imports()` iterators carved out as Phase 11 D6
  follow-up per S-4 reframe"). D-075 status re-scoped from
  "implementation tracker" to "dogfooding gate only" (impl tracker
  duty discharged; row retires when ADR-0109 Status flips Closed).
  Mac 1824/1838 PASS, lint clean, I3 18/18 maintained.
- **10.J / J.7** — `src/zwasm/linker.zig` extended with
  `WasiConfig` + `defineWasi(cfg)`. Native facade routes any
  `wasi_snapshot_preview1` import through existing
  `src/api/wasi.zig::lookupWasiThunk`; thunk receives the host
  via `ctx` directly (NOT via `store.wasi_host` — the latter is
  c_allocator-owned by `wasm_store_delete`, while Linker uses
  Engine's user allocator; allocator-mismatch verified to
  SIGABRT before the ownership lift). `LinkError` gains
  `UnsupportedWasiImport` (phase-11-deferred name) +
  `WasiAlreadyDefined`. T1.13 smoke verifies instantiation
  without exercising syscalls. `test/api/zig_facade_runner.zig`
  outcome flipped 0 PASS / 55 SKIP-WASI → 45 PASS /
  10 SKIP-WASI (Go-toolchain residual under D-177). D-176
  discharged; D-177 opened. Mac 1824/1838 PASS, lint clean,
  I3 18/18, ubuntu kicked post-push (`05c47829`)
- **10.J / J.6** — `test/api/zig_facade_runner.zig` new (~155 LOC).
  Walks a corpus dir, drives each `.wasm` through Engine → Module →
  Instance natively. Pre-scans imports to classify as PASS /
  SKIP-WASI / SKIP-IMPORTS / FAIL-PARSE / FAIL-INST. Wired into
  `build.zig` as `test-api-zig-facade` step + added to `test-all`
  aggregate. Current outcome over test/realworld/wasm/ (55 fixtures):
  0 PASS, 55 SKIP-WASI, 0 FAIL — every realworld fixture imports
  `wasi_snapshot_preview1`, so the SKIP-WASI count flips to PASS
  once J.7's `defineWasi` lands. D-176 opened in same commit
  (blocked-by J.7). Mac 1823/1837 PASS, lint clean, I3 18/18,
  ubuntu kicked post-push (`97434726`)
- **10.J / J.5** — `src/zwasm/{linker,caller,host_func_marshal}.zig` new.
  `Linker.defineFunc(comptime Sig, user_fn)` comptime-derives the Wasm
  signature from the Zig fn's `*Caller` + scalar params; `instantiate(
  module)` parses imports + types natively and runtime-side
  type-checks each func import against the registered host fn's
  comptime-derived Wasm signature (SignatureMismatch surfaces before
  any runtime state). `host_func_marshal.thunkFor(Sig)` comptime-emits
  the per-Sig thunk (pop args, build `*Caller`, `@call` user fn, push
  results). `Caller.memory()` returns the importing instance's
  `Memory` view; `allocator()` returns the per-call allocator.
  `api/instance.zig::instantiateInternal` extracted from
  `wasm_instance_new` body (behaviour-neutral refactor) so both c_api
  and native paths share the post-arena instance setup. 4 tests
  landed: T1.9 host add round-trip, T1.10 caller.memory write+read,
  T1.11 SignatureMismatch on arity mismatch, T1.12 cross-instance
  memory sharing via `defineMemory`. Mac 1823/1837 PASS, lint clean,
  I3 18/18, ubuntu kicked post-push (`b10922d2`)
- **10.J / J.4** — `src/zwasm/typed_func.zig` + `src/zwasm/memory.zig`
  new. `TypedFunc(comptime Sig)` uses `@typeInfo(.@"fn")` +
  `std.meta.ArgsTuple` to derive the call shape; per-scalar marshal
  helpers cover i32/i64/u32/u64/f32/f64 (NaN bits preserved via
  `@bitCast`). Multi-result via anonymous-struct return type
  (`@typeInfo(.@"struct").fields` inline-for walk). `Memory.read /
  write / slice / size` wrap `rt.memory` little-endian for
  i8/i16/i32/i64/f32/f64. `Instance.typedFunc(Sig, name)` +
  `Instance.memory()` added. 4 tests landed: T1.5 add, T1.6 swap
  multi-result, T1.7 Memory i32 round-trip, T1.8 quiet-NaN bit
  preservation. Mac 1819/1833 PASS, lint clean, I3 18/18,
  ubuntu kicked post-push (`995270cf`). Critical-path comptime
  layer completed in 1 cycle (plan estimated 1-2)
- **10.J / J.3** — `src/zwasm/instance.zig` new (native `Instance`);
  c_api veneer `Instance` + `valueToVal`/`valFromApi` deleted from
  `src/zwasm.zig`. `Instance.invoke(name, args, results)` resolves
  exports via `inst.exports_storage`, marshals zwasm.Value →
  runtime.Value into locals, drives `dispatch.run` directly against
  the process-shared dispatch table (lifted `dispatchTable()` `pub`
  in `src/api/instance.zig`), and maps each dispatch error to the
  corresponding `runtime.Trap` variant. `InvokeError = error{
  ExportNotFound, NotAFunc, ArgArityMismatch, ResultArityMismatch }
  || Trap` — all 12 spec trap variants individually addressable
  (no TrapKind round-trip lossiness). `Trap` re-exported from
  `runtime.Trap`. New tests: T1.3 (untyped invoke happy-path),
  T1.4 (div-by-zero → `error.DivByZero`), T1.4-types (`@typeInfo`
  walks the 12 Trap variant names). Mac 1815/1829 PASS,
  I3 18/18, ubuntu kicked post-push (`698c23ce`)


## Row 10.M — memory64 + multi-memory impl

Per ADR-0111 (Accepted 2026-05-25). Source-of-truth:
[`phase10_design_plan_ja.md`](../phase10_design_plan_ja.md) §3.1.
Sub-chunks split per the handover candidate list (1: parser; 2:
runtime cascade; 3: MemArg memidx; 4: codegen; 5: spec corpus;
close: -Dwasm=v2_0 symbol-absence gate).

### Sub-chunks (commit-time order)

- **10.M-spec-corpus** — bake 5 additional memory64 wast
  manifests (`3d6aba35`). Extends the Wasm 3.0 smoke set's
  memory64 coverage from 1 manifest (address64 only) to 6,
  baking the full set of memory64-specific `*64.wast` files:
  align64 / load64 / memory_grow64 / memory_redundancy64 /
  memory_trap64. Each via
  `bash scripts/regen_spec_3_0_assert.sh memory64 <name>`
  (wast2json --enable-all + python distill into the canonical
  directive lines). SMOKE array in the regen script extended
  to match. `memory64.wast` itself excluded — non-standard
  `(module definition ...)` syntax that wast2json rejects;
  the spec-defined memory64 semantics are covered by the
  other 6 manifests. spec_assert_runner_wasm_3_0 skeleton
  (currently enumerate-and-count) now reports memory64
  manifests=6 / module=37 / return=337 / trap=205 / invalid=83
  / skip=62 (was 1/3/27/12/1/0 pre-extend); 9 total wasm-3.0
  manifests / 835 directives. JIT-execute wiring for the
  directives is gated on the runner's
  `spec_assert_runner_base` callbacks pattern adoption per
  the runner's own commentary — per-proposal impl-row scope,
  not 10.M-spec-corpus's. Mac `test-all` GREEN; lint exit 0.
  Per Phase 10 design plan §4.6 corpus 取り込み step.

- **10.M-5b** — SIMD lane-memarg memory64 (`37771003`).
  Closes the 10.M-4b carry-over. `validator_simd.zig::
  readSimdMemarg` + `lower_simd.zig::emitMemargLane` now decode
  the Wasm 3.0 §5.4.6 memarg encoding (align uleb's bit 6
  signals memidx LEB follows; effective log2-align is
  `align & 0x3F` when bit-6 set). Mirrors the scalar
  `lower.zig::emitMemarg` shape landed at 10.M-3. memidx is
  decoded-and-discarded — multi-memory > 1 is rejected at
  instantiate per ADR-0111 D5, so memidx must be 0 in valid
  modules; consuming the uleb keeps validator + lowerer cursor
  positions in sync. The lane variant's `extra` field is
  already consumed by the lane byte, so memidx routing for
  per-lane multi-memory codegen would need a side table when
  the JIT side eventually wires it. The non-lane SIMD ops
  (v128.load / store / *_splat / *_zero) already use the
  shared `Lowerer.emitMemarg` (SIBLING-PUB) and have handled
  bit-6 since 10.M-3 — only the lane variants needed this
  update. 3 new lower_tests (v128.load8_lane with bit-6 +
  memidx=0; v128.store32_lane legacy 2-uleb regression;
  v128.load64_lane with bit-6 + memidx=2). Mac `test-all`
  GREEN; lint exit 0. Wasm spec 3.0 §3.3.7 + §5.4.6;
  ADR-0111 D4 + D5.

## Row 10.R — function-references typed-ref family

Per `phase10_design_plan_ja.md` §3.2. 5-op proposal (GC
prereq): `ref.as_non_null` / `br_on_null` / `br_on_non_null`
/ `call_ref` / `return_call_ref`. Sub-chunks per op (family
allows bundling but each is a distinct dispatch / interp
shape; 1 op = 1 sub-chunk per granularity rule for
architectural-typed work).

### Sub-chunks (commit-time order)

- **10.R-3** — `br_on_non_null` impl (`b31dc63f`). Third op in
  10.R typed-function-references family. lower.zig 0xD6 + uleb
  labelidx → emit `.br_on_non_null` (same `emitUlebPayload`
  shape as 10.R-2). validator.zig 0xD6 → new `opBrOnNonNull`:
  pop reftype (polymorphic funcref/externref/.bot); resolve
  label l; non-null path pushes label_types + reftype before
  branching, null path consumes ref + falls through. Interp
  handler in `function_references.zig` reuses the local
  `branchTo` helper (added at 10.R-2) — null → consume + fall
  through; non-null → push back + branch. 2 new tests: null
  fall-through (ref consumed, pc unchanged) + non-null branch
  (ref carried at top via branch_arity=1, pc jumps). Sibling
  to 10.R-2; 10.R-4/5 (call_ref / return_call_ref) blocked-by
  `(ref $sig)` typed-funcref Value shape (per D-186).

- **10.R-2** — `br_on_null` impl (`86f37b3a`). Second op in
  10.R typed-function-references family. lower.zig 0xD4 + uleb
  labelidx → emit `.br_on_null` (mirror of `br_if`'s
  `emitUlebPayload` shape). validator.zig 0xD4 → new
  `opBrOnNull`: pop reftype (polymorphic funcref/externref
  /.bot); resolve label l; pop label_types from stack (branch
  consumes); push label_types + reftype back (fall-through
  preserves both). Stack pre `[t1*, reftype]` → post (fall)
  same; branch destination expects `[t1*]`. Interp handler
  added to `function_references.zig::register`: pop reftype;
  if non-null push back + return (no branch); if null →
  re-derive branch mechanics locally (label_len/labelAt/
  popLabel + stack restore + pc jump). The ~25 LOC duplication
  vs `interp/mvp.zig::doBranch` is intentional — `instruction/`
  is Zone 1 and `interp/` is Zone 2 (`.claude/rules/zone_deps.md`
  forbids upward import); future refactor could promote
  doBranch to `runtime/frame.zig` to dedupe. 3 new tests:
  register slot for br_on_null; non-null fall-through (ref
  preserved on top, pc unchanged); null branch (ref consumed,
  pc jumps to label.target_pc, stack restored to label.height).
  Mac `test-all` GREEN; lint + zone + fs gates exit 0.

- **10.R-1** — `ref.as_non_null` impl (`fe97f615`). Opens
  10.R with the simplest of the 5 ops. `Trap.NullReference`
  variant added to runtime/trap.zig (spec maps "null
  reference"; zero exhaustive switch cascade per
  platform_panic_vs_error grep). lower.zig 0xD3 → emit
  `.ref.as_non_null` (no immediate). validator.zig 0xD3 →
  new `opRefAsNonNull` (pop reftype polymorphic, push same;
  v2.0 catalogue opaque to nullability axis — typed
  `(ref $sig)` deferred to 10.G WasmGC). New
  `src/instruction/wasm_3_0/function_references.zig`
  register pattern (mirror of wasm_2_0/reference_types.zig)
  with interp handler: pop ref; if `Value.null_ref` → trap;
  else push back. Per-op file
  `src/instruction/wasm_3_0/ref_as_non_null.zig` stays as
  NotMigrated placeholder — dispatch_collector falls through
  to this new legacy registry. `src/api/instance.zig` new
  `wasm_3_0_enabled` comptime flag + `ext_function_references`
  import + register call in `g_dispatch_table_storage` init
  (first wasm_3_0 register hook). 3 unit tests in
  function_references.zig (register slot / non-null pass
  through / null trap). Mac `test-all` GREEN; lint + zone +
  fs gates exit 0.


- **10.M-fixture-2** — OOB-trap + page-edge memory64 fixtures.
  Extends `test/edge_cases/p10/memory64/` with 2 additional
  cases covering trap-condition + exact-equals off-by-one
  stress axes per `.claude/rules/edge_case_testing.md`.
  `oob_trap_past_limit.{wat,wasm,expect}` — i64-indexed
  memory; addr 65533 + i32.load (size 4) → ea+size=65537 >
  mem_limit=65536 → trap "out of bounds memory access".
  `page_edge_load_succeeds.{wat,wasm,expect}` — addr 65532
  + i32.load → ea+size=65536 == mem_limit → succeeds (check
  is `>`, not `>=`). Memory zero-init → returns 0. Both
  share canonical 47-byte memory64 module shape (handcrafted
  WAT); address LEB differs by one bit. Mirror the p7
  past_limit fixture shape but on i64-typed memory,
  exercising validator `memAddrType()` dispatcher + codegen
  `emitMemOpI64` bounds check. p10 corpus 3/3 PASS; total
  111/111 edge_cases (p7=40 + p9=68 + p10=3) PASS. Mac
  `test-all` GREEN; lint + zone + fs gates exit 0.

- **10.M-fixture** — edge_cases/p10/memory64/ store+load
  triple. New `test/edge_cases/p10/memory64/
  store_load_i32_via_i64_addr.{wat,wasm,expect}` —
  `(memory i64 1) (func (export "test") (result i32)
  i64.const 0 i32.const 42 i32.store offset=0 align=2
  i64.const 0 i32.load offset=0 align=2)` returns 42.
  Equivalent semantics to the in-source `runI32Export:
  memory64 store+load` at 10.M-5 (`96dafb3c`); this chunk
  persists the boundary as a canonical runner-walkable
  fixture per `.claude/rules/edge_case_testing.md`. `build.zig`
  threads `run_edge_p10` into `test-edge-cases` aggregate +
  `test-all` (mirrors p7 / p9 pattern; same
  `edge_runner_exe` walks `test/edge_cases/p10/`). Stress
  axes covered: dispatch shape (i32.load on i64-indexed
  memory exercises validator `memAddrType()` + codegen
  `emitMemOpI64`); validator strictness (`skipMemarg`
  bit-6-unset path = implicit memidx=0). Page-edge
  access / large-offset / OOB-trap stress axes deferred to
  10.M-fixture-2. Mac `test-all` GREEN (edge runner
  includes p10 triple); lint + zone + fs gates exit 0.

- **10.M-close** — `-Dwasm=v2_0` symbol-absence gate
  (`b7556472`). Lands
  `scripts/check_phase10_close_invariants.sh` with invariant
  I1: `nm zig-out/bin/zwasm | grep -cE 'emitMemOpI64\b'`
  must return 0 after `zig build -Dwasm=v2_0`. Mechanical
  proof that the i64 emit arm is comptime-DCE'd from the
  v2.0 build per ADR-0111 D4 + Revision 2026-05-25 (user
  collab 1/7). Without this check, the "v2.0 = pure Wasm
  2.0 substrate" guarantee would be runtime-skip-only;
  the nm-grep makes the DCE structural. Verified: default
  v3_0 build has 1 `emitMemOpI64` symbol; -Dwasm=v2_0 build
  has 0. Script restores default cache slot on exit so
  subsequent `zig build` doesn't pay from-scratch rebuild.
  Mirrors `check_phase9_close_invariants.sh` structure;
  future Phase 10 close criteria (GC strip, AOT serialise
  round-trip per ADR-0117) extend this script. 10.M parent
  row stays `[ ]` — additional ROADMAP §10 / 10.M exit
  predicates (edge_cases + spec corpus + realworld/p10/
  clang_wasm64 green) not yet discharged; flipping now is a
  §18.3 violation.

- **10.M-5** — validator memory64 widening + end-to-end test
  (`96dafb3c`). Closes the parser → validator → lowerer →
  codegen → runtime chain. **Validator** (`src/validate/
  validator.zig`): `memory0_idx_type:
  sections.MemoryEntry.IdxType = .i32` field added; legacy
  entries unchanged via default. `skipMemarg` mirrors
  `lower.zig::emitMemarg` byte consumption (bit 6 → optional
  memidx LEB); without this position desyncs on bit-6-set
  memargs. New `memAddrType()` returns `.i32`/`.i64` per
  `memory0_idx_type`; `opLoad`/`opStore` pop address with
  this dispatcher instead of hardcoded `.i32`. **Plumbing**:
  `validateFunctionAndCollectSelectTypesWithMemory` adds 16th
  `memory0_idx_type` param; 1 call site (`engine/compile.zig::
  compileWasm`) already extracted the value at 10.M-4b.
  **End-to-end test**: new `runI32Export: memory64 store+load
  round-trip via i64 idx_type` in `src/engine/runner.zig` —
  hand-crafted 51-byte Wasm 3.0 module `(memory i64 1) (func
  (export "test") (result i32) i64.const 0 i32.const 42
  i32.store offset=0 align=2 i64.const 0 i32.load offset=0
  align=2)` — verifies parser → validator → lower → codegen
  (emitMemOpI64 X-form addr + wrap-check) → runtime
  (Runtime.memories[0].idx_type=.i64). Returns 42 (stored,
  then loaded). Mac-aarch64 gate (existing runI32Export
  pattern). **SIMD coverage**: `validator_simd.zig::
  readSimdMemarg` + `lower_simd.zig::emitMemargLane` still
  hardcode 2-uleb shape; deferred as 10.M-5b (v128.load/
  store on i64-indexed memory; rare for current corpora).
  Mac `test-all` GREEN; lint + zone + fs gates exit 0.

- **10.M-4c** — x86_64 i64 idx_type wrap-check mirror
  (`affef52f`). Closes 10.M-4 cross-arch symmetry. `x86_64/
  ctx.zig::InitArgs` + `EmitCtx` add `memory0_idx_type`
  field; `x86_64/emit.zig::compile` removes the temporary
  `_ = memory0_idx_type;` discard and threads through
  `EmitCtx.init(...)`. `op_memory.zig::emitI32Load` (the
  22-alias wrapper) gains the same comptime + runtime
  2-stage gate as arm64 — when `wasm_level >= .v3_0 AND
  ctx.memory0_idx_type == .i64` dispatch to new
  `emitMemOpI64`; else fall to existing emitMemOp
  (byte-identical i32 fast path). emitMemOpI64 differs at
  TWO points: (1) Idx MOV width `.q` (64-bit full copy) vs
  i32's `.d` (32-bit zero-extend) — Wasm 3.0 §5.4.7 i64
  idx_type semantic; (2) Offset taken as u64 (not u32) for
  memarg offsets > u32::MAX — `encMovImm64Q` already u64-
  typed so MOVABS path needs no encoder change. All other
  shapes (LEA RCX, [RDX+access_size]; CMP RCX, mem_limit;
  JA trap; final MOV/MOVZX/MOVSX/MOVSS/MOVSD with [RAX+RDX]
  base-idx) are X-form already — byte-identical to i32
  path. Mirror of arm64 10.M-4b. Mac `test-all` GREEN; lint
  + zone + fs gates exit 0.

- **10.M-4b** — arm64 i64 idx_type wrap-check emit +
  memory0_idx_type plumbing (`d651d40b`).
  ADR-0111 D4 vertical slice: codegen now distinguishes i32 vs
  i64 memory at the per-arch emit layer. **Plumbing** (16 files):
  `compileOne` (shared) gains 12th param
  `memory0_idx_type: sections.MemoryEntry.IdxType`; arm64 +
  x86_64 `compile()` gain 9th param; arm64 `EmitCtx` adds
  matching field (default `.i32` for ergonomic init).
  `src/engine/compile.zig::compileWasm` reads memory 0's
  idx_type from import memory (precedence) or first defined
  memory; passes through to compileOne. 30+ direct test call
  sites updated mechanically to pass `.i32`. **arm64 emit body**
  (`op_memory.zig::emitMemOpI64`, new): comptime + runtime
  2-stage gate at emitMemOp entry — `if (comptime wasm_level >=
  v3_0) if (ctx.memory0_idx_type == .i64) return emitMemOpI64`
  else falls to existing i32 fast path (byte-identical per
  9 existing emit_test_memory assertions). i64 path differs
  in TWO points: (1) X-form addr load `encOrrReg(ip0, 31,
  w_addr)` vs i32's `encOrrRegW` (zero-extends u32); (2)
  4-lane MOVZ+MOVK offset materialise (lanes 0..3) vs i32's
  2-lane (lanes 0..1) — Wasm 3.0 memarg offset is u64.
  Bounds-check, store value pop, final LDR/STR shapes
  identical (encoders are X-form already; X27 mem_limit is
  u64; validator caps i64 pages at 2^32 per 10.M-1
  compile.zig so ea+access_size cannot overflow u64).
  **Tests**: 2 new emit_test_memory cases — `memory64
  i32.load — X-form addr load` (asserts `encOrrReg` divergence
  at body+4, identical bytes afterward) + `memory64 i64.load
  offset=0x100000000 — 4-lane MOVZ+MOVK` (verifies lane 2
  materialise via `encMovkImm16(17, 1, 2)`). x86_64
  `compile()` accepts the param but discards it (`_ =
  memory0_idx_type;`); body mirror deferred to 10.M-4c. Mac
  `test-all` GREEN (1782/1796; 0 leaks); lint + zone + fs
  gates exit 0.

- **10.M-4a** — codegen memidx==0 invariant assert (`60ec148f`).
  Anchors `MemArgExtra.memidx == 0` at the 2 scalar memory-op
  dispatch points (arm64 op_memory.zig::emitMemOp +
  x86_64 op_memory.zig::emitI32Load 22-alias wrapper) per
  `.claude/rules/comment_as_invariant.md`. Promotes the prose
  invariant "multi-memory routing requires the instantiate-side
  reject lift" to a Debug-runtime assert — any future ZIR
  synthesis path emitting memidx > 0 trips the assert before
  reaching wrong-memory miscompile. Mac `test-all` GREEN
  (existing memory tests don't fire the assert; all current
  lowering paths produce memidx=0 via MemArgExtra default).
  Sub-step for the 10.M-4 i64 wrap-check vertical slice; the
  i64 emit body + `memories[0].idx_type` plumbing land at
  10.M-4b (arm64) and 10.M-4c (x86_64). load_lane/store_lane
  memidx wire-up (parser `emitMemargLane` currently discards
  align bit-6) is a 10.M-4 follow-up.

- **10.M-3** — MemArgExtra + bit-6 memidx decode (`f0809d0c`).
  `zir.MemArgExtra: packed struct(u32) { align_pow2: u5,
  memidx: u8, _pad: u19 }` with `pack`/`unpack` helpers added.
  `lower.zig::emitMemarg` parses Wasm 3.0 §5.4.6 memarg encoding:
  align uleb bit 6 (0x40) signals memidx LEB follows; effective
  log2-align = `raw_align & 0x3F` when bit-6 set, else raw value.
  Range checks: `align_pow2 ≤ 31` (u5) + `memidx ≤ 255` (u8);
  malformed surfaces as new `Error.BadMemarg` (added to
  `lower.Error`; zero exhaustive-switch cascade per
  platform_panic_vs_error grep). Legacy single-memory modules
  (memidx=0) encode as `extra == align` — byte-identical to
  pre-10.M-3 layout, so codegen consumers (op_memory.zig,
  op_alu*.zig) which ignore `extra` for memory ops stay
  transparent. 4 new lower_tests: existing v128.load test
  migrated to `MemArgExtra.unpack` assertion; new tests cover
  bit-6 align=0x42 + explicit memidx=1, implicit memidx=0
  without bit-6, and align=32 reject. Mac `test-all` GREEN,
  lint clean, zone+fs gates exit 0.

- **10.M-2** — Runtime data shape (`939b7bbe`).
  New `src/runtime/instance/memory_instance.zig` introduces
  `MemoryInstance { bytes, idx_type, pages_min, pages_max }`,
  re-exported from `runtime.zig` as `runtime.MemoryInstance`.
  `Runtime.memories: []MemoryInstance` field added (parallel to
  the existing `memory: []u8`); populated to length-1 at every
  instantiate path (defined + imported memory) carrying the
  parsed `idx_type` + page bounds. `Runtime.memory` stays as
  pointer alias of `memories[0].bytes` via new helper
  `setMemory0Bytes(bytes)` — `if (memories.len >= 1) self.memories[0].bytes = bytes`
  (vacuous when memories empty, keeps test-only setups
  invariant-free). Mutation sites switched: `wasm_memory_grow`
  (c_api), `memoryGrow` (wasm_1_0 interpreter handler),
  `allocMem` (bulk_memory test helper). `Runtime.deinit` adds
  `rawFreeOwned(MemoryInstance, memories)` (caught 13-leak
  regression at first build). ~80 `rt.memory` readers stay
  byte-identical — per-memidx code-side rewrite belongs to
  10.M-3/10.M-4 codegen alongside MemArg memidx wire-up.
  Multi-memory > 1 reject (instantiate.zig:572 + :582) stays
  intact: lifting earlier would silently route per-op access to
  memory[0] regardless of declared memidx — correctness
  regression. New `Runtime.setMemory0Bytes` round-trip test
  asserts the alias invariant (empty-vacuous + populated
  cases). Mac `test-all` GREEN, lint clean, zone+fs gates
  exit 0.

- **10.M-1** — parser + validator widening (`063e80e8`).
  `MemoryEntry.idx_type: enum(u1) { i32, i64 } = .i32` field
  added; `min`/`max` widened `u32 → u64`; new `readMemLimits`
  decodes Wasm 3.0 §5.4.4 4-bit flag byte (bits: 0x01 has_max,
  0x02 shared (reject — threads OOS), 0x04 i64, 0x08 reserved),
  accepting 0x00/0x01 always and 0x04/0x05 only when
  `comptime build_options.wasm_level >= .v3_0` (else
  `Error.Memory64Unsupported`). Cascade through
  `ImportPayload.memory` → `ImportShape.memory` (instance.zig)
  + `MemoryImport.source_idx_type` (import.zig) + host linker
  (zwasm/linker.zig). `engine/compile.zig` validator
  per-idx_type page cap (i32: 65536 = 4 GiB; i64: 2^32 per
  Wasm 3.0 §A.1 implementation-limit ceiling). spec_assert
  runner helpers (`extractMemoryLimits`,
  `effectiveMemory0Min/Max`, `extract{Memory,Exporter}Min/Max`,
  `crossModuleMemoryMismatch`, `memLimitsMismatch`) widened
  return types u32→u64; runner call sites use `@intCast` to
  preserve the existing `current_mem_max_pages: ?u32` runner
  state (10.M-2 widens runner state). 6 new parser tests
  (i32 default / i64 min only / i64 min+max / multi-memory /
  shared reject / reserved bits reject). Mac `test-all` GREEN,
  lint clean, zone_check + file_size_check exit 0.



## Row 10.E — Exception Handling impl

**Scope** (parent row §10 / 10.E): regalloc N-successor callsite
拡張 (ADR-0113 §B) + `feature/exception_handling/` (tag +
exception) + `unwind.zig` FP-walk + `zwasm_throw` trampoline
+ `op_exception_handling.zig` landing-pad emit + cross-module
propagation + EH × TC integration + c_api tag accessors +
spec corpus 76 assertion + realworld/p10/emscripten_eh/。
Design source: ADR-0114 + ADR-0117 (cross-subsystem invariants).

**SHA pointer**: backfilled at Phase 10 close.

- **10.E-codegen-4b** — EmitCtx.exception_table_builder field
  substrate (`e06daffe`). Per ADR-0114 D2: adds optional
  `exception_table_builder: ?*exception_table.Builder = null`
  field to both per-arch EmitCtx (arm64/ctx.zig + x86_64/
  ctx.zig). Imports shared/exception_table.zig in both arches.
  Default null preserves back-compat for every existing
  EmitCtx construction site (no positional init breaks; Zig
  struct literals honour the default). Functions containing
  no try_table operate exactly as before; functions with
  try_table populate the pointer at compile-pass setup time
  so per-op `op_exception_handling.zig` emit handlers can call
  `Builder.add(...)` per ADR-0114 D2. This is the substrate
  atom for the try_table emit body; per-op handler integration
  (decoding catch_vec from ZirInstr + calling Builder.add +
  recording pc_start/pc_end fixups) lands next via 4b-2 OR
  4c (throw/throw_ref emit, which doesn't need this field).
  Mac `test-all` GREEN; lint exit 0. ADR-0114 D2.

- **10.E-N-4** — c_api instantiate → Runtime.tag_param_counts
  production wiring (`52b9bb67`). Closes the 10.E-N-3 →
  c_api path. `instantiate.instantiateRuntime` now decodes
  the tag section (via `sections.decodeTags`) + resolves
  each tag's param count via `types.items[entry.typeidx].
  params.len` + assigns to `rt.tag_param_counts`. Modules
  without a tag section keep the default `&.{}`
  (back-compat for every existing c_api test). The interp
  throw / catch path (feature/exception_handling/exception.zig
  + mvp.zig throwOp) now reads production-populated
  `Runtime.tag_param_counts[tag_idx]` instead of test-only
  manually-constructed Runtime state. 2 new c_api unit tests
  in src/api/instance.zig route byte-level Wasm modules
  through wasm_engine_new → wasm_module_new → wasm_instance_new
  → instantiateRuntime, verifying tag-bearing + tag-free
  modules end-to-end. Mac `test-all` GREEN; lint exit 0.
  ADR-0014 §2.1, 10.E-N-3 mirror, Wasm 3.0 §3.3.10.7.

- **10.E-codegen-4** — per-arch EH op_exception_handling
  skeletons (`f5524688`). Per ADR-0114 D2 + ADR-0113 §A/B:
  6 per-op files (3 ops × 2 arches) under
  `engine/codegen/{arm64,x86_64}/ops/wasm_3_0/` —
  `try_table.zig`, `throw.zig`, `throw_ref.zig`. Each
  declares the 3-axis classification: try_table falls
  through into inner block (`is_terminator=false /
  n_successor_edges=1 / is_safepoint=false`; per-callsite
  N for the catch-vec EH-aware metadata populated at
  lower time per ADR-0113 D3); throw / throw_ref are
  terminators (`is_terminator=true / n_successor_edges=0
  / is_safepoint=false`; CALL the zwasm_throw dispatcher,
  never return to caller — mirrors tail-call shape). Emit
  stubs return `UnsupportedOp` pending real bodies: 4b
  for try_table (Builder.add per catch + recursive inner-
  block emit), 4c for throw / throw_ref (payload marshal
  + tag_idx load + CALL dispatcher). Files NOT yet in
  `collected_arch_ops` registry per architectural_spike.md
  (no on-branch spike; wired when emit bodies land).
  6 axisOf comptime tests in `dispatch_collector.zig`
  verify each per-op file's declared axes. Mac `test-all`
  GREEN; lint exit 0. ADR-0114 D2/D6 + ADR-0113 §A/B.

- **10.E-codegen-3h** — frame_bytes-aware SP-restore
  (`e246da18`). Per ADR-0114 D6: completes the SP-restore
  primitive for functions with locals. Three coordinated
  changes — `CodeMap.Entry` gains `frame_bytes: u32 = 0`
  (default for back-compat; arm64 `SUB SP, SP, #N` /
  x86_64 `SUB RSP, #N` frame-allocation size); per-arch
  `emitSpRestoreFull(allocator, buf, src_gpr, frame_bytes)`
  composes `emitSpFromGpr` + the SUB sequence. arm64 splits
  large frame_bytes into LSL-12 + low imm12 per AAPCS64
  large-frame discipline (mirrors emit.zig:1248-1249 epilogue
  ADD pattern); x86_64 promotes Imm8 (≤127) → Imm32 (>127).
  Trampoline call shape: `emitSpRestoreFull(handler_fp,
  code_map.Entry.frame_bytes)` from .handler return path.
  EH landing path now production-shape complete: trampoline →
  dispatchThrow → .handler → emitSpRestoreFull → JMP
  landing_pad_pc. 8 new unit tests (2 code_map + 3 arm64 +
  3 x86_64): defaults; explicit round-trip; arm64 frame=0/16/
  0x12345 (LSL-12 split); x86_64 frame=0/16/256 (Imm8↔Imm32
  promote). Mac `test-all` GREEN; lint exit 0. ADR-0114 D6.

- **10.E-codegen-3g** — x86_64 sp_restore.zig RSP=RBP restore
  emit (`654de49f`). Mirror of 10.E-codegen-3f's arm64
  version. `emitSpFromGpr` emits `MOV RSP, <src_gpr>` (64-bit
  reg-to-reg move). Zero-locals restore: SysV/Win64 prologue
  leaves RBP == RSP at prologue-completion, so `MOV RSP, RBP`
  (= 48 89 EC) is the canonical zero-locals shape; functions
  with locals need follow-up `SUB RSP, #frame_bytes` (lands
  10.E-codegen-3h). 3 byte-snapshot tests: MOV RSP, RBP
  canonical; MOV RSP, RAX (alt src); MOV RSP, R11 (REX.W +
  REX.R encoding for R-high reg). Mac `test-all` GREEN; lint
  exit 0. ADR-0114 D6, System V AMD64 §3.2.2.

- **10.E-codegen-3f** — arm64 sp_restore.zig SP=FP restore emit
  (`9af0770e`). Per ADR-0114 D6: the assembly trampoline calls
  `emitSpFromGpr(allocator, buf, src_gpr)` to emit `MOV SP, Xn`
  (canonical AAPCS64 form `ADD SP, Xn, #0`; opcode 0x91000000
  | (Rn<<5) | Rd) on the .handler return path before jumping
  to landing_pad_pc. Zero-locals restore only — functions with
  locals + spills need a follow-up `SUB SP, SP, #frame_bytes`
  emit that lands when CodeMap.Entry gains the frame_bytes
  field (10.E-codegen-3h follow-on). 3 byte-snapshot tests:
  MOV SP, X29 → 0x910003BF (zero-locals canonical); MOV SP, X1
  (handler_fp landed in X1 after dispatchThrow result marshal);
  MOV SP, X0 → 0x9100001F (encoding cross-check). Mac
  `test-all` GREEN; lint exit 0. ADR-0114 D6, ADR-0017
  (prologue layout: SP == FP at prologue-completion).

- **10.E-codegen-3e** — shared/zwasm_throw.zig Zig dispatcher
  (`a2043d1c`). Per ADR-0114 D6: the entry point invoked by the
  JIT-emitted throw / throw_ref ops (via arch-specific assembly
  glue, 10.E-codegen-3f follow-on). `dispatchThrow(table,
  code_map, ThrowSite, max_unwind_depth)` walks the full
  pipeline: code_map.lookup of the absolute throw-site address
  → initial_pc (with non_jit_pc_sentinel fallthrough for
  non-JIT addresses); builds the adapter Context pinning the
  code_map as the per-frame normalizer; invokes unwind.walk;
  returns the UnwindResult for the caller (assembly glue) to
  act on (.handler → restore SP to handler_fp + JMP
  landing_pad_pc; .uncaught → trap_flag=1 + return 0 to entry
  shim per the existing bounds_fixup trap shape). API:
  ThrowSite { initial_fp, throw_site_addr, tag_idx };
  default_max_unwind_depth = 4096 (Phase 10 cap; Phase 11+
  Runtime override). INVARIANT (paired with ADR-0114 D5/D6 +
  ADR-0112 D7): function body is 4 statements (lookup +
  context build + loader build + walk); no allocator /
  host-call / signal-check between entry and return — local
  safepoint-free audit is unambiguous. 4 unit tests build
  end-to-end pipelines: handler in current frame; uncaught;
  multi-step walk with inner-miss outer-catch_all (DISJOINT
  PC ranges to force the walk step); throw-site address
  outside any JIT function (sentinel falls through initial
  lookup, walker advances to JIT caller frame and catches).
  End-to-end EH unwind data path is now production-shaped —
  only arch-specific assembly entry/exit glue (3f-h) +
  per-arch op_exception_handling.zig (4) remain. Mac
  `test-all` GREEN; lint exit 0. ADR-0114 D5/D6.

- **10.E-codegen-3d** — shared/code_map.zig per-Instance
  JIT code map (`2d6e3c78`). Per ADR-0114 D5: translates
  absolute saved-LR (AAPCS64) / saved-RIP (SysV/Win64) into
  module-relative PC for `ExceptionTable.lookup`. Closes the
  PC-normalization slot exposed by 10.E-codegen-3c's
  `frame_chain_adapter.NormalizePcFn`. `Entry { start_addr,
  len, func_idx }` + `Lookup = .inside{rel_pc, func_idx} |
  .outside` + `CodeMap.lookup` binary search +
  `Builder` (sort-on-finalize). `normalizeForUnwind`
  conforms to `frame_chain_adapter.NormalizePcFn`: `.inside`
  → relative PC; `.outside` → `non_jit_pc_sentinel`
  (= u32 maxInt). The sentinel is load-bearing: no
  `HandlerEntry` covers maxInt, so the unwinder's lookup
  falls through and walks through non-JIT host/OS frames
  until either a real handler or top-of-stack. `adapterContextFor`
  is the convenience constructor the trampoline uses. 10 unit
  tests cover: empty map; single function; PC at start_addr +
  PC at start+len boundary (half-open); below first; in-gap;
  out-of-order add gets sorted; 8-entry binary search +
  gap probes; normalizeForUnwind inside + outside; adapterContextFor
  consume path. End-to-end EH unwind path now fully composable:
  trampoline → adapter ctx (=code_map) → unwind.walk → handler.
  Mac `test-all` GREEN; lint exit 0. ADR-0114 D5.

- **10.E-codegen-3c** — frame_chain_adapter.zig per-arch
  bridge (`a7b22ec2`). Per ADR-0114 D5/D6: bridges the
  per-arch `frame_chain.loadFrame` raw reader to the
  platform-agnostic `unwind.FrameChainLoader` interface via
  a `NormalizePcFn` callback (absolute saved LR/RIP →
  module-relative PC for `ExceptionTable.lookup`). Comptime
  switch on `builtin.target.cpu.arch` resolves the field name
  difference (caller_lr on AAPCS64 / caller_rip on SysV/Win64)
  without renaming landed per-arch files. Mirrors the
  `shared/thunk.zig` + `shared/frame_teardown.zig`
  arch-dispatch pattern. The trampoline (10.E-codegen-3e
  follow-on) supplies the real PC normalizer via the
  per-Instance code-map (10.E-codegen-3d follow-on). 5 unit
  tests: basic load + normalize; fp==0 sentinel; end-to-end
  walk with synthetic 2-frame chain hitting catch_ handler;
  end-to-end walk with empty table → uncaught; probe verifies
  normalizer receives raw absolute address (no pre-mutation).
  End-to-end EH unwind path is now structurally testable —
  only the assembly-stub entry/exit glue + JIT-emit
  integration remain. Mac `test-all` GREEN; lint exit 0.
  ADR-0114 D5/D6.

- **10.E-codegen-3b** — x86_64 frame_chain.zig SysV/Win64
  frame-prefix read (`dcffaba4`). Mirror of 10.E-codegen-3a's
  arm64 version. `loadFrame(fp) ?RawFrameLink` reads the
  RBP-chained prefix at `[RBP, #0]` (saved RBP) + `[RBP, #8]`
  (saved RIP = return address). System V AMD64 ABI §3.2.2
  and Win64 ABI both use the same RBP-chained frame layout
  for this prefix shape, so one file covers both x86_64
  targets — only the prologue's register-save list differs,
  not the FP-chain shape. Same `fp == 0` sentinel; same
  INVARIANT (no alloc / host-call / signal-check). 4 unit
  tests parallel to arm64 version. Mac `test-all` GREEN;
  lint exit 0. ADR-0114 D6, System V AMD64 §3.2.2.

- **10.E-codegen-3a** — arm64 frame_chain.zig AAPCS64
  frame-prefix read (`de2f79fe`). Per ADR-0114 D6 + AAPCS64
  §6.4: `loadFrame(fp) ?RawFrameLink` reads the prologue-
  planted prefix at `[X29, #0]` (saved FP) + `[X29, #8]`
  (saved LR = absolute return address). `fp == 0` returns
  null (top-of-Wasm-stack sentinel planted by the entry
  shim). Raw read only — the trampoline (10.E-codegen-3c
  follow-on) composes this into `unwind.FrameChainLoader`
  via a PC-normalization callback that converts saved-LR
  (absolute address) to module-relative PC for
  `ExceptionTable.lookup`. INVARIANT (paired with ADR-0114
  D5 + ADR-0112 D7): two pointer-relative loads, no alloc /
  host-call / signal-check between entry and return. 4 unit
  tests with synthetic 2-slot u64 arrays: fp==0 sentinel;
  basic 2-slot read; caller_fp==0 propagation; chained walk.
  Mac `test-all` GREEN; lint exit 0. ADR-0114 D6, ADR-0017
  (prologue layout), Arm IHI 0055 §6.4.

- **10.E-codegen-2** — shared/unwind.zig FP-walk algorithm
  (`3b0000ad`). Per ADR-0114 D5: platform-agnostic frame-chain
  walker callable from per-arch zwasm_throw trampoline.
  `walk(table, throw_tag_idx, initial_pc, initial_fp, loader,
  max_depth) → UnwindResult.{handler|uncaught}`. The FP register
  conventions are ABI-pinned per platform (AAPCS64 X29, SysV /
  Win64 RBP) but the walk algorithm is platform-agnostic — the
  per-arch trampoline (10.E-codegen-3 follow-on) supplies the
  `FrameChainLoader.load_fn` that materialises one chain step.
  `FrameLink { caller_fp, caller_pc }` is the per-step shape;
  `HandlerLanding { landing_pad_pc, kind, handler_fp }` carries
  the catching-frame's FP so the trampoline can restore SP +
  push the exnref before jumping. `max_depth` bounds corrupted
  chains. Single-Instance only for Phase 10 (cross-instance
  EH dispatched per-frame deferred to 10.E-codegen-2b at
  Phase 11+ per ADR-0114). INVARIANT (paired with ADR-0112 D7):
  no allocator / host-call / signal-check in the walk body.
  7 unit tests with synthetic in-memory frame chains: handler
  in current frame; no handler → uncaught; walk to caller +
  catch; catch_all matches any tag; max_depth on self-cycle;
  loader returning null → uncaught; handler_fp reports
  catching frame at depth 2. Mac `test-all` GREEN; lint exit
  0. ADR-0114 D5, exception_table.zig + ADR-0112 D7.

- **10.E-codegen-1** — shared/exception_table.zig storage
  (`34f81932`). Per ADR-0114 D3: per-Instance EH handler table
  with `HandlerEntry { pc_start, pc_end, tag_idx, landing_pad_pc,
  kind }` records + `ExceptionTable.lookup(pc, throw_tag_idx) →
  ?HandlerMatch` linear scan + `Builder` accumulator with
  `kind ↔ tag_idx-presence` invariant asserts. Keys on `tag_idx`
  (the module's tag-section index) matching the interp's
  `feature/exception_handling/exception.zig` keying — migration
  to `*TagInstance` pointer-equality (ADR-0114 D7) happens
  on both sides together. Insertion order = innermost-try_table
  first; first match wins (per Wasm 3.0 §4.5.10). PC range
  `[pc_start, pc_end)` half-open. Per-function sorted-by-PC
  binary-search optimisation deferred to Phase 11+. 7 unit
  tests: empty table; catch_ exact match + miss; catch_all any
  tag in range; catch_ref / catch_all_ref kind propagation;
  insertion-order wins for nested try_table; PC end exclusive;
  Builder.finalize aliases entries. Consumed by 10.E-codegen-2
  (unwind.zig FP-walk) + 10.E-codegen-4 (per-arch
  op_exception_handling.zig). Mac `test-all` GREEN; lint exit
  0. ADR-0114 D3, ADR-0113 (callsite_metadata cohort).

- **10.E-N-3** — production tag_param_counts wiring through
  CompiledWasm (`d2f8e5c7`). `CompiledWasm.tag_param_counts:
  []u32` field added; compileWasm pre-resolves per-tag param
  counts from `tags_slice[i].typeidx → types[typeidx].params.len`
  on both return paths (main path + empty-function early-return,
  the latter decoding tags + types on-demand so modules with
  just types + tags get a populated slot too). Out-of-range
  `tag.typeidx` → `Error.InvalidFuncIndex`. `CompiledWasm.deinit`
  frees the slice when non-empty (mirrors globals_offsets
  discipline). 3 new compileWasm unit tests (single i32-param
  tag → [1]; no tag section → empty; 3 tags with mixed-arity
  types → [0, 2, 0]). The consumer at `Runtime.tag_param_counts`
  already exists (10.E-N-2); production wiring through
  `instantiate.instantiateRuntime` lands as 10.E-N-4 when the
  JIT-side EH codegen exercises throw via the interp bridge.
  Until then, tests construct Runtime directly + set the slot
  from a test-built slice. Mac `test-all` GREEN; lint exit 0.
  Wasm spec 3.0 §4.5; ADR-0114 D1.

- **10.E-exnref-b** — throw_ref interp impl (`e448356d`).
  `throwRefOp` (0x0A) pops the exnref, resolves the wrapped
  `*Exception` via `Value.refAsExceptionPtr` + `@ptrCast +
  @alignCast`, writes to `rt.pending_exception`, then re-enters
  `findAndDispatchCatch` against the current frame. The
  Exception heap object is NOT re-allocated — throw_ref just
  routes the existing object back through the unwinder, so
  catch arms match against the original tag_idx + payload.
  On a local match the slot is cleared; on miss the trap
  propagates via the existing 10.E-5d cross-frame unwind path.
  Null exnref → `Trap.NullReference` per Wasm spec 3.0
  §3.3.10.8 step 2. 2 new mvp_tests: nested try_table with
  inner catch_all_ref grabbing original throw + body re-raises
  via throw_ref + outer catch_all_ref catches the re-raised
  exnref (verifies `rt.live_exceptions.len == 1` — single
  Exception object, no re-allocation); null exnref → trap
  (pushed via `.ref = null_ref` directly, not via i32.const 0
  — extern-union poison-byte trap when only the .i32 field
  is set would race the null check on garbage upper bytes).
  Mac `test-all` GREEN; lint exit 0. Wasm spec 3.0 §3.3.10.8;
  ADR-0114 D1 + D6. This completes the EH interp foundation
  (throw + throw_ref + try_table + 4 catch flavors +
  cross-frame unwind + exnref). Remaining EH work is
  production-side: tag_param_counts wiring in compileWasm
  (10.E-N-3); regalloc N-successor codegen impl per ADR-0114
  D3-D6; spec corpus integration.

- **10.E-exnref-a** — Exception heap object + catch_all_ref /
  catch_ref dispatch (`49cf7157`). New
  `feature/exception_handling/exception.zig` (Zone 1) with
  `Exception { tag_idx: u32, payload_len: u32, payload:
  [max_payload]Value }` (max_payload=16; inline storage). Deviates
  from ADR-0114 D1's eventual `extern struct { *TagInstance,
  [*]Value, ... }`: `tag_idx` substitutes for *TagInstance until
  cross-module tag identity wires through (single-module
  validator-range-checked tag_idx is sufficient for now); inline
  payload eliminates one allocation per throw (cap matches
  max_block_arity which the validator already enforces). Value
  gains `fromExceptionRef(*anyopaque)` + `refAsExceptionPtr` —
  opaque pointer avoids the cycle of feature/exception_handling
  importing back into runtime/value. Runtime now carries
  `pending_exception: ?*Exception` (was inline struct value) +
  `live_exceptions: ArrayList(*Exception)` tracker freed at
  deinit (pre-GC leak strategy; ADR-0117 I1 GC walker enumerates
  exception payloads at 10.G). throwOp allocates per throw,
  appends to live_exceptions, writes pointer to
  pending_exception. findAndDispatchCatch signature now takes
  `*Exception`; gains `catch_all_ref` arm (pushes 1-element
  [exnref] payload) and `catch_ref` arm (matches by tag_idx,
  pushes `[payload..., exnref]` via stack-local combined buffer
  capped at `max_exception_payload + 1`). invoke() cross-frame
  unwind threads the new pointer-based contract. 2 new mvp_tests
  (catch_all_ref: throw 0 caught, exnref lands on inner block,
  rt.live_exceptions.len==1; catch_ref with i32 param tag:
  [88, exnref] pushed, drop removes exnref, 88 returned).
  Mac `test-all` GREEN; lint + zone + fs gates exit 0. Wasm
  spec 3.0 §3.3.10.6-8 + §4.5; ADR-0114 D1 + D6; ADR-0117 I1.

- **10.E-5d** — cross-frame throw unwind (`82be1d75`).
  `Runtime` gains `PendingException { tag_idx, payload_len,
  payload: [16]Value }` + `max_exception_payload = 16` constant
  + `pending_exception: ?PendingException = null` slot. Per
  ADR-0114 D6 the codegen path uses a thread-local `zwasm_throw`
  trampoline slot; interp variant lives directly on Runtime
  (single-threaded per Runtime in v2). `throwOp` writes the
  popped payload + tag_idx into the slot before walking the
  local frame's catch vec; on local match clears the slot and
  succeeds; on no local match leaves the slot set and propagates
  `Trap.UncaughtException`. `invoke()` (the shared call-machinery
  helper used by callOp / callIndirectOp / callRefOp) wraps
  `dispatch.run(callee.instrs)` with a post-popFrame intercept:
  if `run_err == Trap.UncaughtException` AND
  `pending_exception != null` AND a caller frame still exists,
  retry `findAndDispatchCatch` against the caller. On caller-frame
  match clears the slot and returns success (dispatch resumes at
  catch's target label in caller's body); otherwise re-raises.
  Laddering across nested invoke calls keeps the slot set across
  arbitrary-depth unwind. 2 new mvp_tests: outer
  `(block (result i32) (block (try_table (catch_all 0))))`
  wrapping `call inner` where inner throws — outer's catch_all
  branches to inner-block end (arity=0 to avoid payload-type
  mismatch with the catch_all variant), then `i32.const 42`
  fills the outer-block result; verifies operand stack [42]
  + pending_exception cleared. Negative: no outer try_table →
  trap propagates with pending_exception surviving so a
  top-level caller could inspect tag_idx. Mac `test-all` GREEN;
  lint exit 0. Wasm spec 3.0 §3.3.10.7-8 + §4.5; ADR-0114 D6.
  This completes the EH interp foundation (throw + catch_ +
  catch_all + cross-frame). Remaining 10.E work: exnref +
  catch_ref / catch_all_ref dispatch (10.E-exnref); production
  Runtime.tag_param_counts wiring (10.E-N-3); regalloc-side
  codegen impl; spec corpus.

- **10.E-5c** — interp catch_ dispatch with tag-equality +
  payload push (`3cbb12aa`). Bundles 10.E-N-2 (Runtime
  tag_param_counts) since the latter was unobservable
  without the former consuming the popped payload.
  `Runtime.tag_param_counts: []const u32 = &.{}` field
  pre-resolves per-tag param counts from
  `module.tags[i].typeidx → module_types[typeidx].params.len`
  at module setup; default empty preserves existing test /
  runner paths (throw pops 0 params as safe fallback).
  `throwOp` now pops `rt.tag_param_counts[tag_idx]` operand
  values into a stack-local `payload_buf` (capped at
  `max_block_arity`=16) before walking the catch vec.
  `findAndDispatchCatch` gains `payload: []const Value`
  parameter + `catch_` arm matching when
  `entry.tag_idx == thrown_tag_idx`, then unwinds via new
  `dispatchCatchWithPayload` helper (manual pop-labels +
  set operand_len + push payload — doBranch can't be reused
  because its restoreToLabel uses target.branch_arity
  (block result count) rather than tag's param count).
  `catch_ref` / `catch_all_ref` stay deferred pending exnref.
  2 new mvp_tests: catch_ with matching tag_idx + i32 param →
  caught with payload pushed at target block (block's end
  pops the catch's i32 → function returns 77); catch_ with
  non-matching tag_idx → falls through to UncaughtException.
  Previous 10.E-5b "currently uncaught — defers to 10.E-N"
  placeholder test superseded; the negative case is now
  the non-matching-tag test. Mac `test-all` GREEN; lint
  exit 0. Wasm spec 3.0 §3.3.10.7 + §4.5; ADR-0114 D3.

- **10.E-N-1** — Module.tags wiring through validator
  (`aa60df61`). `Validator.tags: []const sections.TagEntry =
  &.{}` field added (default empty preserves existing
  `validateFunction` 9-arg call sites). Two new entry points:
  test-side `validateFunctionWithTags(...10 args + tags)`
  mirroring `validateFunction`'s shape; production
  `validateFunctionAndCollectSelectTypesWithMemory` extended
  with trailing `tags` param. `compileWasm` decodes the tag
  section via `sections.decodeTags(a, ts.body)` when
  `module.find(.tag)` is non-null (arena-allocated; freed
  when `a` deinits), threads through. `opThrow` now strict:
  range-checks `tag_idx >= self.tags.len → Error.InvalidTagIndex`
  (new variant), looks up `tags[tag_idx].typeidx →
  module_types[typeidx]`, pops params via
  `popLabelTypes(blockTypeOfSlice(ft.params))` (last-first,
  matching spec stack order), then markUnreachable.
  `validateCatchVec` range-checks tag_idx on `catch_` (0x00)
  and `catch_ref` (0x01); catch_all variants stay
  label-only. 8 new validator tests (throw with valid /
  out-of-range / no-tags / matching i32 param / underflow /
  type mismatch; try_table catch out-of-range tag_idx;
  catch_all with empty tags). 2 existing 10.E-4 tests
  migrated from `validateFunction` to the new wrapper
  (their placeholder bodies threw against an empty tags
  slice, which is now strictly rejected). Mac `test-all`
  GREEN; lint exit 0. Wasm spec 3.0 §3.3.10.7 + §4.5;
  ADR-0114 D3. 10.E-N-2 lands interp-side wiring
  (Runtime sees tags so throwOp can pop dynamic param
  values for catch_/catch_ref dispatch at 10.E-5c).

- **10.E-5b** — interp throw unwinder, catch_all only
  (`d8a4aa43`). `Label.block_idx: u32 = 0` added to
  `runtime.frame.Label`; populated by `blockOp` / `loopOp` /
  `ifOp` (try_table reuses blockOp) from `instr.payload`. New
  `findAndDispatchCatch` walks the current frame's label stack
  inward-out (depth 0 = innermost); for each label whose owning
  `BlockInfo.kind == .try_table`, scans the matching
  `LandingPad` in `func.eh_landing_pads` (linear by `block_idx`
  equality, since try_tables are rare per body). On `catch_all`
  match dispatches via `doBranch(depth + 1 + catch.label_idx)`
  — the `+ 1` skips past the try_table's own label per the
  validator's catch-label numbering (`validateCatchVec` runs
  *before* `pushFrame(.try_table, …)`, so catch `label_idx=0` is
  the label just outside try_table, not the try_table itself).
  `catch_` / `catch_ref` matching is deferred — Module.tags
  wiring (10.E-N) is needed for tag-equality + param
  marshalling; `catch_all_ref` is deferred for exnref support
  (10.E-N). When no catch matches in the current frame,
  propagates `Trap.UncaughtException` (cross-frame unwind →
  10.E-5d). `throwRefOp` still uncaught pending exnref. 4 new
  mvp_tests (throw caught by enclosing catch_all → outer block
  end with operand stack preserved; throw with no try_table →
  uncaught; catch_-only try_table → uncaught until 10.E-N pins
  the deferred behavior; Label.block_idx default + blockOp
  population regression). Mac `zig build test-all` GREEN; lint
  + zone + fs gates exit 0. Wasm spec 3.0 §3.3.10.7-8 + §4.5;
  ADR-0114 D3.

- **10.E-5a** — EH catch metadata storage + lowerer wire-up
  (`da1cec05`). `zir.CatchKind` enum (catch_ / catch_ref /
  catch_all / catch_all_ref; raw byte values 0x00..0x03 per
  Wasm 3.0 EH §4.5), `zir.CatchEntry { kind, tag_idx,
  label_idx }`, filled `zir.LandingPad { block_idx,
  catches_start, catches_end }` (was empty struct slot
  reserved on ZirFunc since Phase 10 open). ZirFunc gains
  two new owned-slice slots: `eh_landing_pads: ?[]const
  LandingPad` (one per try_table in body order) and
  `eh_catch_entries: ?[]const CatchEntry` (flat backing —
  LandingPad ranges are half-open slices into this).
  `ZirFunc.deinit` frees both alongside the existing
  `simd_consts` discipline. Lowerer: `skipCatchVec` renamed
  to `lowerCatchVec`, decodes each spec catch entry into
  `Lowerer.catch_entries: ArrayList(CatchEntry)`;
  `openTryTable` records the half-open slice on a fresh
  `LandingPad` appended to `Lowerer.landing_pads:
  ArrayList(LandingPad)`. Both builders transfer ownership
  to the ZirFunc slots at `run()` close via `toOwnedSlice`
  (mirror of `simd_consts` flush). Dead-region try_tables
  (D-093) `shrinkRetainingCapacity` back so the unreachable
  branch never leaves LandingPad-less catch data on the
  builder. 5 lower_tests (empty catch vec / catch+catch_all
  mixed / catch_ref+catch_all_ref / nested try_tables with
  flat catch entries / malformed kind byte rejected as
  `Error.BadBlockType`). Wasm spec 3.0 §3.3.10.6 +
  §4.5; ADR-0114 D3 interp-side metadata. Mac `test-all`
  GREEN; lint + zone + fs gates exit 0. Interp unwinder
  consuming this data lands at 10.E-5b.

- **10.E-4** — throw / throw_ref opcodes (`753aec8f`).
  Lower emits + markUnreachable; validator `opThrow` reads
  tag_idx + markUnreachable (tag-param popping pending
  Module.tags wiring at 10.E-N); `opThrowRef` pops any
  reftype + markUnreachable. Interp `throwOp` / `throwRefOp`
  return new `Trap.UncaughtException` variant. 5 new
  validator unit tests (polymorphic-stack via throw /
  unreachable code after throw / throw_ref pop+unreachable /
  underflow / type mismatch). Real unwind lands at 10.E-5b
  consuming the 10.E-5a catch metadata.

- **10.E-3b** — try_table opcode 0x1F + catch-vec parse
  skeleton (`da8880a9`). Lowerer `openTryTable` +
  `skipCatchVec` (later replaced at 10.E-5a); validator
  `opTryTable` + `validateCatchVec` (label-range only —
  type-matching pending 10.E-5).

- **10.E-3a** — `BlockKind.try_table` enum entry + validator
  `labelType` arm (`c2238c9a`).

- **10.E-2** — `decodeTags` + `TagEntry` (`390856f8` +
  `cec18589`). Module.tags storage shape; runtime/validator
  wiring at 10.E-N.

- **10.E-1** — tag section parse skeleton (`ffb56dd7`).


## Row 10.G — WasmGC impl

**Scope** (parent row §10 / 10.G): Value.anyref arm + needs_gc_heap
parse-time flag + needs_heap_detector + feature/gc/heap.zig +
Collector vtable + regalloc stack-map (ADR-0113 §C) + collector_null
(α) + delegation + i31 + RTT 8-deep + op_gc family + op_i31 +
collector_mark_sweep (β) + gc_stress_runner + cross fixtures +
spec corpus ~578 assertion + realworld (dart + wasm_of_ocaml +
hoot). Design source: ADR-0115 + ADR-0116.

**SHA pointer**: backfilled at Phase 10 close.

- **10.G-3** — detectNeedsGcHeap heap-top reftype scan
  (`8bebcc76`). Extends the parse-time predicate (ADR-0115 D2) to
  flag heap-managed-ref usage even when no GC type declaration
  is present. New `scanForHeapReftype` byte-stream scan walks
  type / global / table / element / code section bodies looking
  for any of anyref (0x6E) / eqref (0x6D) / i31ref (0x6C) /
  exnref (0x69). Function / import sections are intentionally
  not scanned (typeidx LEB128s only; reftype reach resolves
  through the scanned type section). Original
  `scanTypeSectionForGcTags` renamed to `scanForGcDeclTags` for
  symmetry. False-positive tolerance preserved per ADR-0115 D2
  (a coincidence-matching byte over-triggers the flag; cost is
  an empty-heap walk at instantiate, never correctness). 7 new
  tests (anyref / eqref / i31ref / exnref in each scanned
  section; function-section typeidx isolation; clean (i32)→(i32)
  regression). Module-level docstring updates the "Current
  coverage" list and removes "heap-top reftype" from
  "Future coverage". Mac `test-all` GREEN; lint exit 0.
  Wasm spec 3.0 GC §5.3 (heap-type encoding); ADR-0115 D2.

- **10.G-2** — needs_gc_heap parse-time predicate (`d5810162`).
  Byte-scan type section for struct/array/rec declaration tags.
  10.G-3 extended to cover heap-top reftype bytes.

- **10.G-i31-ops** — 3 i31 ops interp impl (`52a6c225`).
  Value helpers + 0xFB GC prefix dispatcher.

- **10.G-i31-helpers** — pack/unpack helpers under
  `feature/gc/i31.zig` (`e79bb7a1`).


## Row 10.TC — Tail Call impl

**Scope** (parent row §10 / 10.TC): regalloc terminator-class
拡張 (ADR-0113 §A) + `op_tail_call.zig` per-arch + frame_teardown
shared helper + cross_module_tail_call inline emit (no ADR-0066
thunk re-use) + interp trampoline (re-derived; v1 vm.zig
read-only) + safepoint-free comptime invariant + spec corpus
(95 wast) + realworld (clang_musttail + wasm_of_ocaml).
Design source: ADR-0112 (Accepted 2026-05-25) + ADR-0113 §A.

**SHA pointer**: backfilled at Phase 10 close.

- **10.TC-3e** — same-module callee_rt restore helpers
  (`2b6242c5`). Lands step (2) of the ADR-0112 D3/D4 tail-call
  emit sequence for the same-module case (caller_rt ==
  callee_rt). `arm64/op_tail_call.zig::emitLoadCalleeRtSameModule`
  emits `MOV X0, X19` (ORR X0, XZR, X19 — canonical AAPCS64
  reg-to-reg move idiom); `x86_64/op_tail_call.zig` equivalent
  emits `MOV RDI, R15` (4C 89 FF = REX.W+REX.R + MOV r/m64,r64
  + ModR/M with mod=11 reg=7 rm=7). Sources via
  `abi.runtime_ptr_save_gpr` constants (X19 / R15). The
  callee's prologue does `MOV X19, X0` (arm64; ADR-0017
  sub-2d-ii) / `MOV R15, RDI` (x86_64; ADR-0026 Cc-pivot),
  so the caller must deliver runtime_ptr in X0 / RDI before
  the BR / JMP. Cross-module case (caller_rt != callee_rt)
  routes through 10.TC-3f cross_module_tail_call.zig
  (deferred). 4 unit tests (2/arch): byte-snapshot + ABI
  constant sanity. Mac `test-all` GREEN; lint exit 0.
  ADR-0112 D3/D4, ADR-0017, ADR-0026.

- **10.TC-3d** — op_tail_call.zig per-arch helpers
  (`176b00f5`). Lands step (5) of the ADR-0112 D3/D4 tail-call
  emit sequence: `arm64/op_tail_call.zig::emitTailJump` emits
  `BR X16` (0xD61F0200 canonical AAPCS64 IP0 indirect branch
  per Arm IHI 0055 §6.4 + ADR-0066 thunk convention);
  `x86_64/op_tail_call.zig::emitTailJump` emits `JMP R11`
  (41 FF E3 = REX.B + FF /4 ModR/M; R11 chosen over RAX to
  avoid callee-prologue clobber conflict). Both files expose
  `tail_target_gpr` constant (arm64=16, x86_64=.r11) as the
  canonical convention. Per ADR-0112 D2 these are sibling
  files to `op_call.zig` (not extensions) so the regular-call
  vs tail-call shapes don't accumulate dual-meaning drift
  across Phase 11+. Per-op-file wire-up + steps (1)-(4)
  integration land at 10.TC-3e together with
  `collected_arm64_ops` / `_x86_64_ops` registration. 6 unit
  tests: arm64=3 (BR X16 byte / BR X17 alternate / target
  constant) + x86_64=3 (JMP R11 byte / JMP RAX cross-check /
  target constant). Mac `test-all` GREEN; lint exit 0.
  Safepoint-free invariant (ADR-0112 D7) audit home docked
  in both file headers. ADR-0112 D2/D3/D4/D7.

- **10.TC-3c** — frame_teardown.zig shared helper (`23ae7da2`).
  Per ADR-0112 D3: `arm64/frame_teardown.zig` emits the
  ADD-SP-then-LDP-X29,X30 teardown (mirroring the regular
  arm64/emit.zig epilogue lines ~1245-1252 minus the trailing
  RET); `x86_64/frame_teardown.zig` emits ADD-RSP-then-POP-RBP
  (Imm8 form for ≤127, Imm32 for larger); `shared/frame_teardown.zig`
  is the arch-agnostic facade dispatching via
  `builtin.target.cpu.arch` (same pattern as
  `shared/thunk.zig` / `shared/compile.zig`). The shared
  `Params` struct exposes the 4-axis ADR-0112 D3 inputs
  (`n_clobber_saved` / `frame_bytes` / `n_incoming` /
  `n_outgoing`); currently only `frame_bytes` is consumed,
  the others are plumbed through for future ADR-0066 §A2 /
  D-144 pinned-cohort restoration + AAPCS64 §6.4.2
  overflow-region adjustment. Safepoint-free invariant
  (ADR-0112 D7) maintained: emit body has no allocator /
  host-call / signal-check operations. 10 unit tests: 4
  arm64 byte-snapshot (frame=0/16/0x12345/RET-absence),
  6 x86_64 byte-snapshot (frame=0/16/256/RET-absence + Imm8
  127 boundary + Imm32 128 boundary), 2 facade smoke (host
  arch resolution). Mac `test-all` GREEN; lint exit 0.
  Consumed by 10.TC-3d op_tail_call.zig. ADR-0112 D3/D7.

- **10.TC-3b** — tail-call per-op file skeletons + terminator
  axes (`cbc3d587`). Creates `engine/codegen/{arm64,x86_64}/
  ops/wasm_3_0/` directories with `return_call.zig` /
  `return_call_indirect.zig` / `return_call_ref.zig` (6 files,
  3 ops × 2 arches). Each declares `is_terminator=true /
  n_successor_edges=0 / is_safepoint=false` per ADR-0112 D2
  (separate op_tail_call.zig design; not an extension of
  op_call.zig) + ADR-0112 D7 (safepoint-free invariant between
  teardown and BR X16 / JMP R11) + ADR-0113 §A (terminator
  axis: tail-jump leaves the function, no fallthrough). Emit
  stubs return `error.UnsupportedOp` pending the shared
  `op_tail_call.zig` + `frame_teardown.zig` helpers (10.TC-3c
  / 10.TC-3d follow-on). Files are NOT yet registered into
  `collected_arm64_ops` / `_x86_64_ops` — per
  `.claude/rules/architectural_spike.md` the wiring lands when
  the emit body has substance (no on-branch spike). 6 new
  `axisOf` comptime tests in `dispatch_collector.zig` verify
  the terminator classification fires for all 6 per-op files
  (the observable behavior point of this chunk). Mac
  `test-all` GREEN; lint exit 0. ADR-0112 D2/D7 + ADR-0113 §A.

- **10.TC-3a** — ADR-0113 §A 3-axis foundation (`7447be67`).
  Lands the per-op file 3-axis (`is_terminator` /
  `n_successor_edges` / `is_safepoint`) classification pattern
  defined by ADR-0113 §A. New `Axis3` struct + `axisOf(comptime
  mod: type)` helper in `engine/codegen/dispatch_collector.zig`
  reads each axis via `@hasDecl` with safe defaults
  (`false / 1 / false` — matches the regular-call shape so
  pre-migration per-op files classify sanely). First two
  per-op file migrations: arm64 + x86_64
  `ops/wasm_1_0/call.zig` declare `is_terminator=false /
  n_successor_edges=1 / is_safepoint=true` (the non-default
  axis is `is_safepoint`: a regular call IS a GC safepoint
  per ADR-0115/0116 root-walk contract). 4 unit tests: empty
  mod → defaults; arm64 call → declared values; x86_64 call →
  declared values; partial override (only is_terminator
  declared) → declared + defaults. The downstream consumers
  (regalloc terminator-class extension at 10.TC-3b, EH
  N-successor at 10.E-codegen, GC stack-map at 10.G) read via
  `axisOf` when they land. Mac `test-all` GREEN; lint exit 0.
  ADR-0113 §A.

- **10.TC-1b** — return_call / return_call_indirect /
  return_call_ref validator unit test coverage (`b7562e5c`;
  pre-this-cycle); 6 tests.

- **10.TC-1** — return_call + return_call_indirect interp impl
  + tailReturn helper (`a83e095f`; pre-this-cycle).
