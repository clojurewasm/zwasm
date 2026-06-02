# Phase 10 設計プラン (実装方針版 / r3)

> **Doc-state**: DRAFT (uncommitted; レビュー用)
> **対**: `.dev/phase10_transition_gate_ja.md`, `private/notes/p10-design/{01..12}-*.md`
> **目的**: あるべき論 (clean architecture / comptime DCE / 責務分離 / zero-cost-when-unused / 集約性 / テスト先付) で各設計判断を再評価し、具体的にやることを述べる
> **r2 → r3 変更**: Q1 (spike なし直接実装) / Q2 (wall-clock 試算削除) / Q3 (parse-time `needs_gc_heap`) / Q4 (realworld 9 fixture / 5 toolchain 確定) / Q5 (専用 dir 作らず既存 `emit_test_*` 拡張) を確定反映

---

## §1. 設計原則 (Phase 10 全工程の判断軸)

| 原則                                          | 具体 |
|-----------------------------------------------|------|
| **comptime build-option DCE**                 | 各 Phase 10 op 配下ファイルが `pub const wasm_level: ?WasmLevel = .v3_0;` 宣言。`dispatch_collector.zig` (既存) が `build_options.wasm_level < .v3_0` で comptime skip。`-Dwasm=v2_0` で Phase 10 シンボル不在 (`nm` 検証 invariant 化) |
| **module-driven 起動**                        | `Module.needs_gc_heap: bool` を parse 時に決定 (型 section / table 型 / import 型 / function 型を OR 走査)。Wasm 3.0 GC 型 (anyref / struct / array) を使わないモジュールは collector init / stack-map alloc / heap allocate 全 skip。wasmtime 命名揃え |
| **Zone 規約遵守**                             | runtime 状態 = Zone 1 (`feature/<sub>/`); per-arch emit = Zone 2 (`engine/codegen/<arch>/op_*.zig`); cross-arch helper = Zone 2 (`engine/codegen/shared/`); upward import 禁止 (zone_check --gate) |
| **責務分割は迷ったら split**                  | `single_slot_dual_meaning.md` 抵触の閾値で同ファイル拡張禁止。tail_call は op_call.zig 拡張ではなく op_tail_call.zig 新規 |
| **zero-cost-when-not-thrown / not-allocated** | EH: try-table エントリ 0 命令 (wasmtime model); GC mark-sweep STW = barrier ゼロ; memory64: i32 fast-path 既存と byte-identical (`emit_test_*.zig` で守る) |
| **packed struct で命名された invariant**      | bit-packing は raw `<<` ではなく `packed struct(uN)` で明示し comptime assert; 違反は `comment_as_invariant.md` rule で検出 |
| **side-table over field 拡張**                | per-function meta (stack_map / exception_table) は `Function` に nullable field 追加ではなく side-table (`IP → metadata` map) で参照 |
| **業界一致は引き継ぐ、divergence は明記**     | wasmtime model を base、各 ADR References に divergence 3 件まで列挙 |
| **vtable パターンを Zig 慣習に揃える**        | collector 切替 / host GC delegation は `std.mem.Allocator` 形の vtable (既存パターン)。comptime mono は採用しない |
| **テスト先付**                                | spec-corpus 取り込み + edge_cases fixture (Stress axis ≥ 1 件) + 既存 `emit_test_*.zig` golden 拡張 + cross-subsystem integration を per-chunk landing 規律化 |
| **完成形への妥協なし**                        | wall-clock / chunk 数 試算しない (AI 速度で着実進行)。依存順に test infra 配備しつつ Phase 10 完遂が目標 |

---

## §2. ディレクトリ・ファイル配置 (確定; full 命名)

```
src/instruction/wasm_3_0/         (per-op IR/validate/interp; §9.12-G で全 placeholder 配置済)
  memory64 は対応不要 (既存 op に idx_type axis 追加)
  function_references/* + gc/* + tail_call/* + eh/* placeholder を実装で埋める

src/feature/                       (Zone 1)
  memory64/
    register.zig
    index_type.zig                (IndexType enum + Memory.idx_type 配線)
  function_references/
    register.zig
    typed_ref.zig                 ((ref $sig) 型管理)
  tail_call/
    register.zig                  (状態なし; 純 dispatch)
  exception_handling/
    register.zig
    tag.zig                       (Tag instance + import/export 解決)
    exception.zig                 (例外ヒープオブジェクト)
  gc/
    register.zig
    heap.zig                      (per-Store contiguous slab; vtable 経由で collector に委譲; wasmtime gc_store model)
    object_layout.zig             (struct/array header + 16-byte align + source-order fields)
    type_hierarchy.zig            (3 hierarchy; RTT 8-deep display + walk-up fallback)
    i31.zig                       (low-bit = 1 discriminant)
    collector_iface.zig           (Collector vtable; std.mem.Allocator 形)
    collector_null.zig            (Phase 10 α; bump until OOM; test-only)
    collector_mark_sweep.zig      (Phase 10 β; STW; barrier ゼロ; 必須 ship)
    delegation.zig                (Mode A 自前 + Mode B host root provider hooks)
    needs_heap_detector.zig       (parse 時 needs_gc_heap 判定; type/table/import/global/function/element section OR 走査)

src/engine/codegen/<arch>/        (Zone 2; arch ∈ {arm64, x86_64})
  op_memory.zig                   (既存; memory64 wrap-check 分岐を追加; 1 ファイル増加なし)
  op_call.zig                     (既存; 触らない)
  op_tail_call.zig                (新規)
  op_function_references.zig      (新規; call_ref / return_call_ref / ref.as_non_null / br_on_null{,_non})
  op_exception_handling.zig       (新規; try_table / throw / throw_ref; landing pad emit)
  op_gc.zig                       (新規; struct / array / ref.test / ref.cast / br_on_cast; GC は業界用語)
  op_i31.zig                      (新規; ref.i31 / i31.get_{s,u} / convert_extern/any; i31 は spec 用語)

src/engine/codegen/<arch>/        (golden test 拡張; 既存 emit_test_*.zig パターン継承; J-3 結論)
  emit_test_tail_call.zig         (新規; ~5-7 ops 代表 byte-snapshot)
  emit_test_eh.zig                (新規; try_table / throw landing-pad emit snapshot)
  emit_test_gc.zig                (新規; struct.new / array.new / ref.cast 代表; ~10 ops)
  emit_test_memory64.zig          (新規; i64 mem op wrap-check shape)
  ※ 専用 test/golden_asm/ ディレクトリ作らない (J-3); Zone-2 in-source の現行パターン継承

src/engine/codegen/shared/        (Zone 2; cross-arch)
  bounds_fixups.zig               (既存 → callsite_metadata の 1-edge specialisation に refactor; API 維持)
  callsite_metadata.zig           (新規; 1-successor + N-successor 汎用基盤; §3.4)
  frame_teardown.zig              (新規; tail-call SP/FP/LR/callee-saves teardown)
  cross_module_tail_call.zig      (新規; inline-emit; thunk 経由しない)
  exception_table.zig             (新規; wasmtime 6-array 形; callsite_metadata 上に build)
  stack_map.zig                   (新規; precise GC roots; IP → []RegSlot side-table)
  unwind.zig                      (新規; FP-walk; OS unwinder 不使用)

test/                              (Phase 9 4 層を Phase 10 で拡張)
  spec/wasm-3.0-assert/           (新規; proposal repo .wast 取り込み)
    memory64/ tail_call/ exception_handling/ gc/ function_references/
  edge_cases/p10/                  (新規; subsystem 別 + cross/ sub-dir)
    memory64/ tail_call/ exception_handling/ gc/ function_references/
    cross/                        (C(4,2)+1 = 7 pair fixtures; cross-subsystem)
  runners/
    gc_stress_runner.zig          (新規; heap pressure + collector race-free + reentry guard)
    eh_frequency_runner.zig       (新規; throw rate × catch depth matrix)
  realworld/p10/                   (新規; 9 fixture / 5 toolchain; §4.3)
    dart/                         (GC + EH; Dart 3.6)
    wasm_of_ocaml/                (GC + EH + TC 三冠; wasm_of_ocaml 6.0.1)
    hoot/                         (GC + TC; Guile Hoot 0.8.0)
    emscripten_eh/                (EH only; emscripten -fwasm-exceptions)
    clang_musttail/               (TC only; __attribute__((musttail)))
    clang_wasm64/                 (memory64; clang --target=wasm64-unknown-unknown + emscripten -sMEMORY64=1)
```

四層構造 — `feature/<sub>/register.zig` (dispatch 登録) / `engine/codegen/<arch>/op_<sub>.zig` (per-arch emit) / `engine/codegen/shared/` (cross-arch helper) / `test/edge_cases/p10/<sub>/` (boundary fixture)。golden snapshot は **既存 `emit_test_*.zig` パターン拡張**で別 dir 不要。

---

## §3. サブシステム別実装方針

### §3.1 memory64

**やること**:

1. `MemoryEntry` (parse) + `Memory` (runtime) に `idx_type: enum { i32, i64 }` 追加。常時存在 (build-option で消さない; ABI 安定性)。parser が i64 flag を読んだとき `comptime build_options.wasm_level < .v3_0` なら parse-time reject。
2. **ZirInstr 128-bit 拡張** — 業界全社 (wasmtime / wasmer-LLVM / WAMR / spec ref) が memarg offset を full u64 で持つ実態に追従:
   ```zig
   pub const ZirInstr = struct {
       op: ZirOp,
       payload: u64 = 0,    // memarg offset full u64; 他 op では他用途
       extra: u32 = 0,      // align / memidx / etc.
   };
   ```
   現状 `payload: u32 + extra: u32 = 12 byte` → 新 `payload: u64 + extra: u32 + padding = 24 byte`。10^6-instr モジュールで +12 MB overhead 試算。`packed struct(u32) MemArgExtra { align_pow2: u5, memidx: u8, _: u19 }` で extra を明示。
3. `bounds_fixups: ArrayList(u32)` は触らない (idx_type 非依存; callsite_metadata 統合は §3.4 で別途)。handler body のみ wrap-check + offset materialise 分岐。
4. **multi-memory を先に enable** (codegen 0 コスト; runtime の `memory: [*]u8` → `memories: []MemoryInstance` 化)。memory64 はその後 idx_type 分岐で。
5. ARM64: 64-bit offset は MOVZ+MOVK 4-lane で X17 に materialise → `[X_base, X17]`。x86_64: MOV imm64 → r10 → `[r_base + r10]`。
6. i32 fast-path byte-identical 保証 — `if (comptime build_options.wasm_level >= .v3_0) { if (idx_type == .i64) { … } }` 二段 nest。`-Dwasm=v2_0` 完全消滅、v3_0 でも i32 path は元のまま。`emit_test_memory64.zig` で per-chunk byte 確認 + 既存 `emit_test_memory.zig` も i32 path 維持 verify。

**テスト戦略**:

- spec corpus: `~/Documents/OSS/WebAssembly/memory64/test/core/*.wast` (127 files) を `test/spec/wasm-3.0-assert/memory64/`
- edge_cases (`test/edge_cases/p10/memory64/`):
  - `i64_offset_zero.wat` / `i64_offset_0xFFFFFFFF.wat` (spec 実テスト最大値)
  - `i64_offset_overflow_trap.wat` (base + offset overflow)
  - `multi_mem_i32_i64_mixed.wat`
  - `i64_above_4gib_allocate.wat` (host 64-bit only)
  - `i64_growable_reject_32bit_host.wat`
- golden snapshot: `emit_test_memory64.zig` (i64 wrap-check shape) + 既存 `emit_test_memory.zig` 更新 (i32 path 維持確認)
- realworld: `realworld/p10/clang_wasm64/` (memory64 ビルド; emscripten -sMEMORY64=1)

**ADR**: 1 本 (`ADR-0111 memory64 design`)。divergence: (A) ZirInstr 128-bit 拡張, (B) idx_type は Memory に置く, (C) MemArg を packed struct で明示。

### §3.2 function-references (GC prereq; 独立 proposal)

**やること**:

1. `feature/function_references/` を起こす。typed function ref `(ref $sig)` の型を `typed_ref.zig` で管理。Value union arm は §3.5 `.funcref: u32` で既存 (Phase 2 で既追加; 拡張不要)。
2. ops: `ref.as_non_null` / `br_on_null` / `br_on_non_null` / `call_ref` / `return_call_ref`。`src/instruction/wasm_3_0/` 内 placeholder 5 件存在; 中身を埋める。
3. `engine/codegen/<arch>/op_function_references.zig` 新規 (5 op 同居; family 一致なので bundle OK)。
4. call_ref は cross-module 可能性あり → 既存 `cross_module_call.zig` (thunk path) 再利用。return_call_ref は §3.3 `cross_module_tail_call.zig` 経由。
5. spec testsuite: `function-references/test/core/` 149 wast のうち GC-relevant deltas を `test/spec/wasm-3.0-assert/function_references/`

**テスト戦略**:

- edge_cases: `call_ref_null_trap.wat` / `br_on_null_edge.wat` / `typed_ref_signature_mismatch.wat`
- golden: 既存 `emit_test_call.zig` 拡張で `call_ref` 代表追加 (新規ファイル不要)

**ADR**: 単独 ADR 不要 (small)。`ADR-0112 Tail Call design` の References §で言及。

### §3.3 Tail Call

**やること**:

1. ZIR 配置確認: `src/instruction/wasm_3_0/return_call{,_indirect,_ref}.zig` 既存。各 `wasm_level: .v3_0` + handler 実装で埋める。
2. `engine/codegen/<arch>/op_tail_call.zig` 新規 (`op_call.zig` 拡張ではない; single_slot_dual_meaning 適用)。
3. `engine/codegen/shared/frame_teardown.zig` 新規。引数: `{ n_clobber_saved: u8, frame_bytes: u32, n_incoming: u8, n_outgoing: u8 }`。SP 調整 + LDP X29,X30 + X19/X24-X28 復元を 1 ヶ所集約。`prologue.zig` / `epilogue.zig` (ABI-pinned) は触らない。
4. `engine/codegen/shared/cross_module_tail_call.zig` 新規。cross-module tail-call は **inline emit** (既存 thunk は call-and-return 形で構造非互換):
   - marshal args → X1..X7 / V0..V7 (teardown 前; caller frame 上)
   - load callee_rt + callee_entry from caller's literal pool → X0 / X16
   - frame_teardown.emit(…)
   - BR X16
5. **regalloc terminator-class 拡張**: `engine/codegen/shared/regalloc.zig` の op 分類に `is_terminator: bool` 追加。per-op file の `pub const is_terminator: bool = true;` を return_call/return_call_indirect/return_call_ref に。
6. interpreter: `src/interp/` に trampoline pattern。v1 `vm.zig:838-889` 形 (flag + outer loop) を**読んで再導出**、コピペしない。fixed-16 buffer 廃止、`[MAX_PARAMS]u64` stack scratch。
7. **safepoint-free invariant**: tail-call thunk + cross_module bridge に allocator call / host call / signal-check branch なし。`pub const is_safepoint: bool = false;` を per-op file で comptime assert。

**テスト戦略**:

- spec corpus: `tail-call/test/core/` 95 wast を `test/spec/wasm-3.0-assert/tail_call/`
- edge_cases: `mutual_recursion_even_odd.wat` / `tail_call_arg_overflow.wat` / `cross_module_tail_call.wat` / `return_call_indirect_sig_mismatch.wat` / `return_call_in_try_table.wat`
- golden: `emit_test_tail_call.zig` (tail-call epilogue + BR/JMP shape; ~5 op 代表)
- realworld: `realworld/p10/clang_musttail/` (C `__attribute__((musttail))`) + `realworld/p10/wasm_of_ocaml/` (OCaml 関数型 tail 多用)

**ADR**: 1 本 (`ADR-0112 Tail Call design`)。divergence: (1) inline cross-module emit, (2) op_tail_call.zig 新規分割, (3) frame_teardown.zig 集約。

### §3.4 callsite_metadata 汎用基盤 + Exception Handling

**やること**:

1. **`engine/codegen/shared/callsite_metadata.zig`** 新規。汎用形:
   ```zig
   pub const CallsiteEdge = struct {
       kind: enum { normal_return, trap_to_stub, exception_landing_pad },
       target_pc: u32,
       live_ins: []const RegSlot,
   };
   pub const Callsite = struct { pc: u32, edges: []const CallsiteEdge };
   ```
   **既存 `bounds_fixups.zig` をこの上に refactor** (1-edge specialisation; API 維持で internal 差替え)。新規 `exception_table.zig` も同上 (2-edge)。
2. `feature/exception_handling/` 配下:
   - `tag.zig`: Tag instance heap object + import/export 解決
   - `exception.zig`: `extern struct Exception { tag: *TagInstance, payload: [*]Value, payload_len: u32, param_count: u32 }`
   - `register.zig`: try_table / throw / throw_ref dispatch 登録
3. `engine/codegen/<arch>/op_exception_handling.zig` 新規。
4. `engine/codegen/shared/exception_table.zig` 新規 (wasmtime 6-array 形を `callsite_metadata` 上に)。
5. **regalloc N-successor 拡張**: §3.3 と同 file (regalloc.zig)。callsite が複数 edge 持つ場合の handling 追加。`gc_root_map` / `terminator-class` と独立 axis。ADR-0113 で 3 直交 axis 統合。
6. **unwind 機構**: **FP-walk** (wasmtime model; Mac aarch64 / Linux x86_64 / Win64 全て同コード)。`engine/codegen/shared/unwind.zig` 新規 — frame chain walk + handler PC lookup。
7. ADR-0103 SEH (Win64 trap-recovery) は流用しない。EH 専用 trampoline `zwasm_throw(tag, params)` を thread-local state + 1 asm trampoline で。Trap (signal/VEH) と Throw (software) の dispatcher は別 path。invariant: caught-by-try-table は Exception-class only (`comment_as_invariant` で comptime assert)。
8. **Tag identity**: `*TagInstance` ポインタ等価で matching (cross-module も day-1; wasmtime context-SP-offset 形採用)。
9. wasm-c-api: tag accessor は spec 完備 (`include/wasm.h:252-296`) — `wasm_tagtype_*` を c_api 拡張。

**テスト戦略**:

- spec corpus: `exception-handling/test/core/` 4 wast / 76 assertion を `test/spec/wasm-3.0-assert/exception_handling/`
- edge_cases: `throw_basic_catch.wat` / `try_table_nested_100.wat` / `cross_module_throw_propagation.wat` / `payload_v128_carry.wat` / `trap_not_caught_by_try_table.wat` / `exnref_lifetime.wat`
- `test/runners/eh_frequency_runner.zig`: throw rate (0% / 1% / 50% / 100%) × catch depth (1 / 10 / 100) matrix (hot path regression detector)
- golden: `emit_test_eh.zig` (try_table entry が 0 命令 = pure metadata を snapshot)
- realworld: `realworld/p10/emscripten_eh/` (C++ exception heavy)

**ADR**: 2 本 — `ADR-0113 callsite metadata + regalloc 3-axis extension` + `ADR-0114 Exception Handling design`

### §3.5 WasmGC

**やること**:

1. **`feature/gc/` 構造** (Zone 1; per-Store contiguous slab + per-Instance stack-map tables; wasmtime gc_store model):
   ```
   heap.zig                  Per-Store contiguous slab; vtable 経由で collector 呼出
   object_layout.zig         struct/array header (8-byte) + 16-byte align + source-order fields
   type_hierarchy.zig        3 hierarchy + RTT 8-deep display + walk-up
   i31.zig                   Low-bit = 1 discriminant; arith-shift sign-extend
   collector_iface.zig       Collector vtable (std.mem.Allocator 形)
   collector_null.zig        bump until OOM (Phase 10 α; test-only)
   collector_mark_sweep.zig  STW; barrier ゼロ (Phase 10 β; 必須 ship)
   delegation.zig            Mode A 自前 + Mode B host root provider hooks
   needs_heap_detector.zig   parse 時 OR 走査; predicate = "heap-top in {any, extern, exn} OR struct/array type decl OR (ref $T) signature OR import of GC type"
   ```

2. **`Module.needs_gc_heap: bool` parse 時判定** (Q3 確定; wasmtime 命名揃え):
   - 単一 OR'd bit を type / table / import / global / function / element section walk 中に立てる
   - predicate: 「heap-top が {any, extern, exn} を含む」または「struct / array 型宣言」または「(ref $T) シグネチャ」または「GC 型 import」
   - **parse-time 判定** — lower-time でなく; glue/re-export module (型 declare + cross-instance ref hold + 自前 alloc なし) で root scan 必要なケースに対応 (lower-time だと alloc op が 0 で false negative)
   - Instance 初期化で false → heap allocate + collector init + stack-map alloc 全 skip → Wasm 1.0/2.0 モジュール zero overhead
   - 「declared but never alloc」(spec testsuite 例: `type-subtyping.wast` 109 type-decls / 0 allocs) は false positive 許容 — root scan が必要なら正しい

3. **Collector vtable** (Q3 確定; pluggable):
   ```zig
   pub const Collector = struct {
       allocObjectFn: *const fn (ctx: *anyopaque, ti: *TypeInfo) ?GcRef,
       collectFn: *const fn (ctx: *anyopaque) void,
       walkRootsFn: *const fn (ctx: *anyopaque, callback: RootCallback) void,
       ctx: *anyopaque,
   };
   ```
   `-Dgc-collector={null,mark_sweep}` build-option で選択。両 collector を Phase 10 で ship (β は必須 ship; null は test-only)。`-Dgc=false` 完全 strip option も用意 (WAMR 形 nuclear strip)。

4. **Host GC delegation** (Q4 r2 既決; CWFS 等 GC'd host 対応):
   - **Mode A (default)**: zwasm 自前 GC; `zwasm_runtime_with_root_scope(rt, callback)` で root pinning
   - **Mode B (opt-in; ~50 LOC)**: host が `RootProvider` vtable 提供; collect 時に zwasm が host root 列挙を import
   - **Mode C**: defer (type-registry public 化が必要; v0.1.0 RC 越え)

5. **ArenaAllocator backing**: `std.heap.ArenaAllocator` で GC heap slab を確保 → 1 slab = 4 KB page 単位 → grow 時に新 slab 追加 → collect 時に free-list 再構築。ADR-0014 §6.K.2 単一アロケータ規約は GC heap が Runtime arena sub-region であり保たれる (amend 不要)。

6. **Value union 拡張** (3 arm 並列):
   ```zig
   pub const Value = extern union {
       i32: i32, i64: i64, f32: f32, f64: f64,
       v128: [16]u8,
       funcref: u32,    // Phase 2 既存 (Functions hierarchy)
       externref: u32,  // Phase 2 既存 (External hierarchy)
       anyref: u32,     // Phase 10 新規 (Internal hierarchy)
   };
   ```

7. **GC heap 形**: per-Store contiguous slab; 32-bit indexed `GcRef`; object 2-byte align で low-bit = i31 discriminant 不変; null = 0 sentinel; 4 GiB cap。

8. **regalloc stack-map 拡張** (ADR-0113 §C): per-Instance stack-map table (not per-function field; J-1 推奨)。safepoint marker は per-op metadata (`pub const is_safepoint: bool = …;`)。

9. **`engine/codegen/<arch>/op_gc.zig`** — struct/array/ref.test/ref.cast/br_on_cast。`op_i31.zig` 別ファイル (i31 family 小; bundle で肥大化避ける)。

**テスト戦略**:

- spec corpus: `gc/test/core/gc/` 18 wast / ~578 assertion + function-references deltas を `test/spec/wasm-3.0-assert/gc/`
- edge_cases:
  - `struct_new_field_init_default.wat` / `struct_get_set_packed_i8.wat`
  - `array_new_fixed_zero_len.wat` / `array_oob_trap.wat` / `array_copy_overlap.wat`
  - `ref_test_subtype_chain.wat` / `ref_cast_failure_trap.wat`
  - `rtt_depth_9_walkup.wat`
  - `i31_sign_extend_min.wat`
  - `glue_module_root_scan.wat` (J-1 patterns reflection; declare + import (ref) 持つが alloc なし — needs_gc_heap=true verify)
- `test/runners/gc_stress_runner.zig`:
  - heap pressure (10^5 obj alloc → collect → re-alloc)
  - allocation-during-collect reentry guard
  - cyclic struct collect (mark-sweep cycle 回収 verify)
- cross-subsystem (`test/edge_cases/p10/cross/`):
  - `gc_x_eh_thrown_ref_rooted.wat`
  - `gc_x_tail_call_thunk_safepoint_free.wat`
  - `gc_x_memory64_array_new_data.wat`
- golden: `emit_test_gc.zig` (~10 op 代表; struct.new / array.set / ref.test 等)
- realworld: `realworld/p10/dart/` + `realworld/p10/wasm_of_ocaml/` + `realworld/p10/hoot/`

**ADR**: 3 本 — `ADR-0115 GC heap + collector` + `ADR-0116 GC roots + RTT + i31` + `ADR-0117 GC × EH × TC integration invariants`

### §3.6 Native Zig API rewrite (ADR-0109 Accepted 2026-05-25)

ROADMAP §10 / 10.J carries the 6-8 implementation cycles per
ADR-0109 (`docs/zig_api_design.md` consumer spec)。 既存
`src/zwasm.zig` (507 LOC, ADR-0025 minimum-subset c_api veneer)
を first-principles native facade に置換:

- **Engine + Module + Instance** (1-step compile;
  `engine.compile(bytes) → Module`; `module.instantiate() →
  Instance` or `linker.instantiate(module) → Instance`)
- **TypedFunc(comptime Sig: type)** + multi-result via Zig
  anonymous struct return
- **Linker** builder + host imports + `Caller` ctx for host
  functions
- **Memory** slice view (`mem.slice() → []u8`; bounds-checked
  `sliceAt` / `read(T, offset)` / `write(offset, value)`)
- **Trap** full error set (12 spec variants preserved; no
  `error.Trap` catchall)
- **Allocator strict-pass** through `Engine.init(alloc, opts)`
- **WASI bulk** `linker.defineWasi(cfg)` (skeleton in Phase
  10; full impl drives Phase 11)

**内部 rename `runtime.Runtime` → `runtime.JitRuntime`** が先頭。
JIT-emitted code が `[X19 + offset]` で読む ABI 表面は維持しつつ、
public facade に `Engine` 名を譲るため。10.M / 10.R / 10.TC /
10.E / 10.G が `runtime/` を触る前に landing したい (rename 後送
りで触る場合の rename churn 防止)。

**Value 16-byte uniform** (ADR-0110 Accept 後の現実) — facade も
同 union を expose; v128 first-class、別 `V128` type は無し。c_api
側は spec-prohibited per `wasm-c-api include/wasm.h:329-338`。

**Gating**: J.0 amend round 後、pre-impl codebase-investigation
(subagent-driven; enumerates every site needing change) +
execution plan + integrated test strategy を 1 plan doc に統合し
**user review**。J.1+ impl chunks は plan 承認後に開始。

**ADR**: ADR-0109 (Accepted) + ADR-0025 (Superseded; design
lineage retained)。
**Test discipline**: regression detection + happy path + edge
cases — "other tests pass while Zig API is broken" cannot happen
(user direction 2026-05-25; plan doc が test 配置を具体化)。

---

## §4. テスト戦略 (Phase 9 4 層 → Phase 10 拡張)

### §4.1 既存 4 層の Phase 10 マッピング

| 層                  | 既存 (Phase 9)                              | Phase 10 拡張                                                                                  |
|---------------------|---------------------------------------------|------------------------------------------------------------------------------------------------|
| `zig build test`    | in-source `test "..."` block per-handler   | per-op file `wasm_level: .v3_0` + handler unit test; collector 単体 (alloc/collect round-trip) |
| `test/spec/`        | wasm-1.0-assert + wasm-2.0-assert (2 runners) | + `wasm-3.0-assert/{memory64,tail_call,exception_handling,gc,function_references}/` (5 sub-corpora) + `spec_assert_runner_wasm_3_0.zig` 新規 |
| `test/edge_cases/`  | p7 + p9 (Stress axes per fixture)           | + `p10/<sub>/` per subsystem + `p10/cross/` 7 pair                                              |
| `test/realworld/`   | 55 wasm; stdout/exit diff vs wasmtime       | + `realworld/p10/` (9 fixture / 5 toolchain; §4.3)                                              |
| **既存 `emit_test_*.zig`** | per-family byte snapshot (in-source Zone 2) | + 新 family 用 `emit_test_{tail_call,eh,gc,memory64}.zig` (~50 op 代表; J-3 推奨)              |

### §4.2 新カテゴリ (Phase 10 で追加)

| 新カテゴリ                       | 配置                              | 目的                                                                                                          |
|----------------------------------|-----------------------------------|---------------------------------------------------------------------------------------------------------------|
| **cross-subsystem integration**  | `test/edge_cases/p10/cross/`      | C(4,2) = 6 pair + 1 triple (GC × EH × TC) = 7 fixture; per-feature spec runs 不可                              |
| **gc_stress_runner**             | `test/runners/gc_stress_runner.zig` | heap pressure / reentry guard / cyclic — spec corpus 範囲外                                                   |
| **eh_frequency_runner**          | `test/runners/eh_frequency_runner.zig` | throw rate × catch depth マトリクス — hot path regression detector                                            |

**専用 `test/golden_asm/` ディレクトリは作らない**: J-3 結論。既存 `src/engine/codegen/<arch>/emit_test_*.zig` (6 arm64 / 2 x86_64 / 2673 行) が既に proto-golden で Zone 2 in-source が正解パターン。新 family は新 sibling file (`emit_test_<family>.zig`) で展開。

### §4.3 realworld 9 fixture / 5 toolchain (2026-05-24 確定; J-2)

| Tier | toolchain | バージョン | カバー sub | fixture 想定 |
|------|-----------|-----------|-----------|--------------|
| 1 | Dart | 3.6+ | GC + EH | HelloWorld / collection ops / async error |
| 1 | wasm_of_ocaml | 6.0.1+ | GC + EH + TC (三冠) | List.fold (TC) / exception raise / record alloc |
| 1 | Guile Hoot | 0.8.0+ | GC + TC | Scheme tail call factorial / list manipulation |
| 1 | emscripten `-fwasm-exceptions` | 3.x | EH | C++ exception throw/catch (try_table 出力) |
| 1 | clang `__attribute__((musttail))` | 18+ | TC | C continuation passing style |
| 1 | clang `--target=wasm64-unknown-unknown` + emscripten `-sMEMORY64=1` | clang 19+, emcc 3.x | memory64 | > 4 GiB allocate + memcpy (host 64-bit only) |

**Phase 11 D-074 bench infra cohort で追加候補** (defer): Kotlin/Wasm (Beta) / TeaVM / SwiftWasm / j2cl
**Hard skip** (2026-05-24 時点 unusable): TinyGo / Rust `become` / wasi-sdk wasm64

`test/realworld/p10/<toolchain>/<sample>.wasm` + expected stdout / exit code; per-fixture allow-list (`test/realworld/skip-list.yaml`) で運用。WAMR patch 形回避 (rebase コスト)。

### §4.4 skip-list 運用

業界 3 形式比較 (J-2 + J-3 で確認):
- wasmtime per-file header (best maintainability) ← **採用**
- wazero line-range skip (best fidelity but per-update fragile)
- WAMR patch files (worst rebase cost) ← **回避**

ADR-0050 skip-impl ratchet 継続。

### §4.5 SKIP-P10-* ratchet 厳格化 (J-2 lesson)

v1 で発覚した「spec 通過後 realworld で出た」5 件 (data_count ordering / D-079 / D-126 / 9.9-i-1 / 9.9-l-1b-d093-d84) 分析より:

**SKIPPED spec assertion = deferred realworld FAIL**。Phase 10 close 時に以下 ratchet を strict 化:
- `SKIP-P10-PARSER-GAP = 0` (Wasm 3.0 parser 全 op 通過)
- `SKIP-P10-EH-GAP = 0` (EH 全 op + landing pad emit OK)
- `SKIP-P10-GC-GAP = 0` (GC 全 op + collector OK)
- `SKIP-P10-MEM64-GAP = 0` (memory64 全 axis OK)
- `SKIP-P10-CROSS-GAP = 0` (cross-subsystem 7 pair OK)

`scripts/check_phase10_close_invariants.sh` で機械検証。Phase 9 で skip→後発 detect の同型パターン予防。

### §4.6 spec corpus 取り込み手順

1. `scripts/import_proposal_corpus.sh <subsystem>` 新規 (Phase 9 `regen_spec_2_0_assert.sh` generalize)
2. proposal repo `test/core/*.wast` を `test/spec/wasm-3.0-assert/<sub>/` に直接 copy + manifest 自動生成
3. `spec_assert_runner_wasm_3_0.zig` 新規 (sub-corpus selector)
4. CI で `test-spec-wasm-3-0` step + `test-all` aggregate 配線

### §4.7 golden snapshot bless workflow

J-3 推奨; 業界統一形 env-var-gated:
- 通常 test run: snapshot mismatch → FAIL
- bless mode: `ZWASM_TEST_BLESS=1 zig build test` で snapshot 自動更新
- CI は bless せず (mismatch = review 要求)
- ~50 op 代表ならば現状の手動 edit (expected byte sequence 直接書き換え) で十分。SIMD で entry 倍化したら sidecar `private/.bless-pending.txt` + `zig build bless` rewriter pattern 検討

---

## §5. r2 → r3 修正

| r2 案 | r3 修正 | 理由 (調査根拠) |
|-------|--------|-----------------|
| Q1 spike → 本実装 (2 段階) | **spike なし; Z.1 chunk が直接実装 + revert で対応** | architectural_spike.md 規律的に observable behaviour 完備で問題なし; spike は 2 度書きで inferior |
| Q2 ~45 chunks / wall-clock 数日 試算 | **試算文言全削除; AI 速度で着実進行** | CLAUDE.md「AI 基準で見積」整合; chunk 数前提の最適化は人間ペース枠 |
| Q3 `Module.uses_gc` parse vs lower 未確定 | **parse-time `Module.needs_gc_heap: bool` 確定** (wasmtime 命名揃え; J-1 推奨) | spec 明示なし; wasmtime 採用; glue-module pattern (type-only + (ref) hold) を lower-time だと取りこぼし |
| Q4 realworld Phase 10 候補 ぼかし | **9 fixture / 5 toolchain 確定** (Dart 3.6 / wasm_of_ocaml 6.0.1 / Hoot 0.8.0 / emscripten EH / clang musttail / clang wasm64) | J-2 で 2026-05-24 時点の安定 toolchain 確認 |
| Q5 `test/golden_asm/` 専用 dir | **専用 dir 作らない; 既存 `emit_test_*.zig` 拡張で対応** (J-3 推奨) | Cranelift / Wasmtime も per-family + in-source; zwasm 既存 `emit_test_*.zig` が既に proto-golden; Zone-2 in-source 維持 |
| (新) Phase 10 close skip ratchet | **`SKIP-P10-{PARSER,EH,GC,MEM64,CROSS}-GAP = 0` invariant 追加** | J-2 v1 lesson: spec 通過後 realworld 発覚 bug の予防 |
| (新) GC heap per-Runtime | **per-Store contiguous slab** (wasmtime gc_store model 揃え) | J-1 推奨; per-Instance stack-map tables 分離 |
| Z.1 (ZirInstr 128-bit) → spike 経由 | **Z.1 直接実装 chunk; spike なし** | Q1 (c) |

---

## §6. comptime build-option DCE 適用

既存パターン (`src/ir/dispatch_collector.zig` line 109-111) を全 Phase 10 op で踏襲:

```zig
// 各 src/instruction/wasm_3_0/*.zig:
pub const wasm_level: ?WasmLevel = .v3_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};
pub const is_terminator: bool = false;  // tail_call ops は true
pub const is_safepoint: bool = false;    // GC allocator-call ops は true
pub const handlers = .{ .validate = …, .lower = …, .interp = … };
```

`-Dwasm=v2_0` ビルドで Phase 10 シンボル不在 (`nm` 検証 = invariant I4)。`-Dwasm=v3_0` + `Module.needs_gc_heap = false` モジュールで GC infra 呼出ゼロ (invariant I5)。

`-Dgc=false` で更に collector 本体まで完全 strip (WAMR 形 nuclear option; Wasm 3.0 でも GC 無し build を可能に — embedded use case 向け)。

### 「常時存在」(DCE しない箇所)

ABI 安定性のため build-option で消せない:
- `Value` extern union の `.anyref: u32` arm (extern union フィールド数は ABI)
- `Memory.idx_type: enum { i32, i64 }` field (extern struct; 値で reject)
- `Module.needs_gc_heap: bool` (parse 時決定; false で zero overhead)
- ZirOp enum の Phase 10 tag (enum range 固定; handler null で零コスト)

---

## §7. 最初のチャンク順序 (Phase 10 内)

| # | チャンク | 種別 | 内容 | windowsmini |
|---|---------|------|------|-------------|
| C9.1 | Phase 9 close 後始末 | infrastructure | §9.11 audit_scaffolding + §9.x 17 行 SHA backfill + bench baseline + widget 9→DONE + Phase 10 row inline 展開 | 不要 |
| J.0 | ADR-0109 amend round + ROADMAP 10.J 行追加 | infrastructure | Status flip / D-075 re-scope / docs reconcile / phase_log/phase10.md row 10.F + 10.J 追加 | 不要 |
| J.invest | **Pre-impl codebase investigation + execution plan + integrated test strategy** | survey/design | subagent-driven; enumerates every change site in `src/zwasm.zig` + `src/api/` + `src/runtime/` + import sites + ABI surfaces; 統合 plan doc は test 設計も含む (regression / happy path / edge cases; "other tests pass while Zig API is broken" 防止); user review gate | 不要 |
| J.1+ | **Native Zig API impl** (ADR-0109) | architectural→emit | plan doc 順序に従う: Runtime → JitRuntime rename → Engine/Module/Instance native → TypedFunc + multi-result → Linker + host imports + Caller → Memory slice view → Trap full set → WASI bulk skeleton → test runner Tier-2 → close。6-8 cycles 想定 | reconcile 1 (rename 後 + close) |
| F.1-F.3 | c_api scalar accessors | emit | D-171/172/173; D-171 minimum-viable は J.0 と並行で `142502a5` landed; 残: D-171 _new/_type + D-172 + D-173 | 不要 |
| Z.1 | **ZirInstr 128-bit 拡張** (直接実装; spike なし) | architectural | 全 emit/regalloc/lower/interp 連動; Phase 9 corpus 全 host 再 green; 既存 emit_test_* baseline 更新; 不味ければ revert | reconcile 1 |
| D.1 | ADR-0111 memory64 design | survey/design | docs-only | 不要 |
| D.2 | ADR-0112 Tail Call design | survey/design | docs-only | 不要 |
| D.3 | ADR-0113 callsite metadata + regalloc 3-axis | survey/design | docs-only | 不要 |
| D.4 | ADR-0114 EH design | survey/design | docs-only | 不要 |
| D.5 | ADR-0115/0116/0117 GC trio | survey/design | docs-only | 不要 |
| D.6 | ROADMAP §12 amend (AOT stack-map budget) | survey/design | docs-only | 不要 |
| T.1 | `scripts/import_proposal_corpus.sh` + `spec_assert_runner_wasm_3_0.zig` 整備 | infrastructure | 5 sub-corpora 切替対応; 空状態で green | 不要 |
| T.2 | `gc_stress_runner.zig` + `eh_frequency_runner.zig` skeleton | infrastructure | empty runners; build wiring | 不要 |
| T.3 | 既存 `emit_test_*.zig` の Phase 9 baseline 採取 + bless workflow 整備 | infrastructure | regression net 整備; ZWASM_TEST_BLESS env var 配線 | 不要 |
| T.4 | `test/realworld/p10/` ディレクトリ skeleton + 9 fixture build script | infrastructure | 5 toolchain インストール + sample wasm 取得 + harness 統合 | 不要 |
| M.1 | multi-memory enable | architectural | `memory: [*]u8` → `memories: []MemoryInstance`; memidx threading | 不要 |
| M.2 | memory64 parse + validator | emit |  |  |
| M.3 | memory64 runtime mmap >4 GiB | emit | 64-bit-host only |  |
| M.4 | memory64 arm64 codegen + emit_test_memory64.zig | emit | wrap-check + offset materialise |  |
| M.5 | memory64 x86_64 codegen + emit_test_memory64.zig | emit |  |  |
| M.6 | memory64 edge_cases + spec corpus + realworld/p10/clang_wasm64/ green | test |  | reconcile 1 |
| R.1-R.3 | function-references | emit | 5 ops + (ref $sig) typing; edge_cases; 3 chunks | reconcile 1 |
| T.5 | regalloc terminator-class (ADR-0113 §A) | architectural | per-op file `is_terminator`; Phase 9 corpus 再 green |  |
| T.6 | op_tail_call.zig + frame_teardown.zig + emit_test_tail_call.zig | emit |  |  |
| T.7 | cross_module_tail_call.zig (inline emit) | emit | thunk 触らない |  |
| T.8 | interp trampoline | emit |  |  |
| T.9 | TC edge_cases + spec corpus + realworld (clang_musttail + wasm_of_ocaml) + EH × TC cross fixture | test |  | reconcile 1 |
| E.1 | regalloc N-successor callsite (ADR-0113 §B) | architectural | bounds_fixups を callsite_metadata に refactor + EH 用 specialisation |  |
| E.2 | feature/exception_handling/ (tag + exception + register) | emit |  |  |
| E.3 | unwind.zig + zwasm_throw trampoline (FP-walk) | emit | SEH 流用しない |  |
| E.4 | op_exception_handling.zig (arm64 + x86_64) + emit_test_eh.zig | emit | landing pad |  |
| E.5 | cross-module exception propagation | emit |  |  |
| E.6 | EH × TC integration test (`return_call_in_try_table.wat`) | test |  |  |
| E.7 | c_api tag accessors | emit | wasm_tagtype_* spec 部分 |  |
| E.8 | eh_frequency_runner 本実装 + EH spec corpus + realworld/p10/emscripten_eh/ green | test |  | reconcile 1 |
| G.1 | Value.anyref arm 追加 + Module.needs_gc_heap flag + needs_heap_detector.zig | architectural | parse-time OR 走査; ABI bump 注記 |  |
| G.2 | feature/gc/heap.zig + object_layout.zig + Collector vtable | architectural | per-Store slab + vtable; ArenaAllocator backing |  |
| G.3 | regalloc stack-map axis (ADR-0113 §C) | architectural | per-Instance side-table |  |
| G.4 | collector_null.zig + delegation.zig (Mode A + Mode B vtable) | architectural |  |  |
| G.5 | feature/gc/i31.zig + op_i31.zig (arm64 + x86_64) | emit | low-bit discriminant |  |
| G.6 | feature/gc/type_hierarchy.zig (RTT 8-deep) | emit |  |  |
| G.7 | op_gc.zig struct family (7 ops; arm64+x86_64; bundled) + emit_test_gc.zig | emit |  |  |
| G.8 | op_gc.zig array family (12 ops; bundled) | emit |  |  |
| G.9 | ref.test / ref.cast / br_on_cast family (4 ops) | emit |  |  |
| G.10 | any.convert_extern / extern.convert_any | emit |  |  |
| G.11 | collector_mark_sweep.zig (Phase 10 β) | architectural | STW; barrier ゼロ |  |
| G.12 | gc_stress_runner 本実装 + cross fixtures (GC × EH × TC × memory64) | test |  |  |
| G.13 | GC spec corpus + realworld (dart + wasm_of_ocaml + hoot) green | test |  | reconcile 1 |
| P.1 | `scripts/check_phase10_close_invariants.sh` 整備 | infrastructure | §8 全 invariant |  |
| P.2 | Phase 10 close: widget 10→DONE; Phase 11 inline 展開 | infrastructure |  | reconcile 1 (final) |

依存順序 — J.0 amend → J.invest (plan + test strategy) → J.1+ Native Zig API impl (Runtime → JitRuntime rename を最初に下ろし 10.M/R/TC/E/G の rename churn 回避) → F.* c_api 残り (J と並行可) → test infra (T.1-T.4) → Z.1 ZirInstr 拡張 → 設計ラウンド ADR → サブシステム別実装。

---

## §8. Phase 10 = DONE invariants 草案

`scripts/check_phase10_close_invariants.sh` を P.1 で整備:

| ID | 内容 |
|----|------|
| I1 | 全 Phase 10 op の per-op file が `wasm_level: .v3_0` 宣言 + handler 非 null |
| I2 | spec testsuite 0 fail / 0 skip-impl on 3 hosts: memory64 (127) + tail-call (95) + function-references deltas + EH (76 assertion) + GC (~578 assertion) |
| I3 | `test/edge_cases/p10/cross/` 全 7 fixture green |
| I4 | `-Dwasm=v2_0` ビルドで Phase 10 シンボル `nm` 不在 (DCE 検証) |
| I5 | `-Dwasm=v3_0` Module.needs_gc_heap=false モジュールで GC heap allocate / collector init / stack-map alloc 全て呼出ゼロ (module-driven 起動 verify) |
| I6 | `-Dgc=false` 完全 strip option 動作 (WAMR 形 nuclear strip; embedded build path) |
| I7 | 既存 `emit_test_*.zig` snapshot: Phase 9 baseline (T.3 で採取) と byte-identical で Phase 10 拡張後 regression なし |
| I8 | `zone_check --gate` exit 0 |
| I9 | `file_size_check --gate` exit 0 |
| I10 | `check_fallback_patterns --gate` exit 0 |
| I11 | bench Phase 10 close vs Phase 9 baseline; per-fixture allow-list で説明済以外の regression なし |
| I12 | ADR-0111-0117 全て Status: Accepted (or Closed) |
| I13 | ROADMAP §12 amend に "stack-map emission compatible with GC root walker" exit criterion 含む |
| I14 | wasm.h tag accessors (spec 252-296) 完備 |
| I15 | safepoint-free invariant: tail-call thunk + cross-module bridge の `is_safepoint = false` を全 op file で comptime assert |
| I16 | regalloc 3 axis (terminator / N-successor / stack_map) いずれも default-off で Phase 9 既存 corpus 完全再 green |
| I17 | `private/spikes/<adr-slug>/` 全て `merged-into-prod` or `rejected` |
| I18 | `.dev/debt.yaml` に Phase 10-scope `trigger-not-fired` masquerade なし |
| I19 | gc_stress_runner + eh_frequency_runner 共に `test-all` aggregate 配線 + green |
| I20 | **SKIP-P10-{PARSER,EH,GC,MEM64,CROSS}-GAP = 0** (J-2 lesson) |
| I21 | `test/realworld/p10/` 9 fixture / 5 toolchain 全 green |
| I22 | skip-list ratchet: Phase 10 完了時 skip-impl count Phase 9 baseline 以下 |
| I23 | widget Phase 10 IN-PROGRESS → DONE; Phase 11 PENDING (or IN-PROGRESS) |

---

## §9. リスク

| ID | 観点 | 緩和策 |
|----|------|--------|
| R1 | ZirInstr 128-bit 化 (Z.1 直接実装; spike なし) が Phase 9 既存 codegen を regress | Z.1 chunk で Phase 9 spec corpus 全 host 再 green + 既存 emit_test_* byte-identical 確認; 不味ければ chunk revert |
| R2 | regalloc 3 axis 同時 landing の regression | ADR-0113 で統合設計; per-axis chunk landing 後 Phase 9 corpus 再 green |
| R3 | callsite_metadata refactor で bounds_fixups API 壊れる | 互換 wrapper を E.1 で landing; bounds_fixups consumer 変更なし |
| R4 | comptime DCE 部分失敗 (Phase 10 シンボル v2_0 混入) | I4 invariant で機械検出 |
| R5 | Value union .anyref 追加で post-A.4g layout 崩れ | extern union 既存 layout 維持を verify |
| R6 | GC stack-map cache field の非-GC build 重荷 | per-Instance side-table; collector 本体は `-Dgc-collector=mark_sweep` 時のみ link; `-Dgc=false` で完全 strip |
| R7 | tail-call thunk に GC safepoint 紛れ込み | safepoint-free invariant を comptime assert (I15) |
| R8 | EH × TC × GC × memory64 interaction 歯抜け | G.12 / E.6 で 7 pair integration test を I3 invariant 化 |
| R9 | windowsmini reconcile flake (D-028 系) | reconcile cycle ごとに 1 retry budget; 2 fail で systematic 判定 |
| R10 | function-references を後回しで GC ブロック | R.1-R.3 を GC G.1 着手前に必須 (T 直後) |
| R11 | bit-packing が `single_slot_dual_meaning` 抵触 | `packed struct(uN)` 明示 + comptime layout assert |
| R12 | Phase 10 仕様変更 (proposal stage 進行) | spec proposal バージョン pin を `.dev/proposal_watch.md` 四半期 review; Phase 10 close 時の spec commit ID を各 ADR で記録 |
| R13 | CWFS 等の GC'd host で「GC inside GC」競合 | Mode A default + Mode B (RootProvider) opt-in で seam 提供; G.12 で integration test 必須 |
| R14 | ArenaAllocator backing が grow ハマる | page 単位 + free-list 再構築を G.2 で実装; gc_stress_runner で 10^5 alloc round-trip |
| R15 | `Module.needs_gc_heap` parse 時判定で漏れ | J-1 patterns reflection edge_case (`glue_module_root_scan.wat`) + 既存 spec corpus で実 detect 確認 |
| R16 | realworld 9 fixture の toolchain 不安定 (2026-05-24 から進化) | T.4 で初期取得; phase 中に toolchain 更新あれば fixture 再ビルド可能な build script を整備; per-fixture allow-list で migration |
| R17 | Phase 9 で発覚した「spec 通過 → realworld 発覚」5 パターン同型再発 | I20 (SKIP-P10-*-GAP=0) + I21 (realworld green) で機械検証 |

---

## §10. 確定事項 (r2 オープン質問 → r3 全解決)

| 質問 | 確定 |
|------|------|
| Q1 ZirInstr 128-bit spike | **spike なし; Z.1 chunk 直接実装** |
| Q2 wall-clock 試算 | **削除** (AI 速度で着実進行) |
| Q3 needs_gc_heap 判定タイミング | **parse-time OR 走査** (wasmtime 形; glue-module pattern 対応) |
| Q4 realworld Phase 10 toolchain | **9 fixture / 5 toolchain** (Dart 3.6 / wasm_of_ocaml 6.0.1 / Hoot 0.8.0 / emscripten EH / clang musttail / clang wasm64) |
| Q5 golden snapshot 配置 | **既存 `emit_test_*.zig` 拡張** (専用 dir 作らない; Zone-2 in-source 維持) |
| Q6 Phase 12 AOT amend | **本 plan D.6 chunk で landing** |
| Q7 ADR 集約度 | **7 本** (ADR-0111-0117) |

---

## §11. 次のアクション

1. レビュー反映
2. `.dev/phase10_transition_gate_ja.md` の §3 サブシステム別チェックリストに本 plan 決定を反映
3. §9.13 hard gate clear (人間協調レビュー)
4. C9.1 → F.1-F.3 → Z.1 → D.1-D.6 (設計ラウンド) → T.1-T.4 (test infra) → 実装陣
