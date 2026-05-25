# Phase 10 execution log

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


## Row 10.F — c_api scalar accessors

**Scope**: wasm-c-api spec 標準 global / table / memory
accessors を `src/api/instance.zig` に追加 (D-171 / D-172 /
D-173; `phase9_close_master.md` §5.3a Phase F)。

**Status**: [ ] (partial; D-171 minimum-viable landed; remaining
chunks queued)

### Sub-chunks (commit-time order)

- **10.F-D171-mv** — D-171 minimum-viable global accessors
  (export-derived path). `Global` opaque handle + `wasm_extern
  _as_global` + `wasm_global_get/set/delete` を追加; mutable
  i32 global in-source test green; Mac test-all green; v128
  permanently spec-prohibited per `2026-05-24-c_api-v128-spec
  -boundary.md` `[x] 142502a5`
- **10.F-D171-full** — `wasm_global_new` + `wasm_global_type`
  (host-side standalone construction; Extern wrap → `wasm
  _instance_new(imports[])` シナリオ用) (planned)
- **10.F-D172** — `wasm_extern_as_table` + `wasm_table_get/
  set/size/grow` (planned)
- **10.F-D173** — `wasm_extern_as_memory` + `wasm_memory_data
  /data_size/size/grow` (planned)


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
