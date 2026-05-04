# _DRAFT_ — ディレクトリ構造・命名の正規化 (ADR-NNNN 候補)

- **Status**: Draft (user 微修正待ち、英語化前最終形)
- **Author**: Shota / 命名・構造ドリフト調査
- **Tags**: roadmap, refactor, naming, structure, modularity, phase7

> 本 ADR で zwasm v2 の `src/` 配下ディレクトリ構造・ファイル命名
> 規約・ROADMAP 修正をすべて確定する。実装順序は本 ADR 末尾に
> 記載するが、commit 単位や 3-host gate の運用は実施時に判断する。
> 関連する周辺修正 (`c_api/instance.zig` 2216 LOC の分割等) も
> 本 ADR scope 内に含める (関連 ADR への分散を避ける)。

---

## 1. 課題

zwasm v2 の現状ディレクトリ構造は、ROADMAP §4.5 / §5 の計画と
実装が乖離しており、放置すると Phase 8 以降の x86_64 + AOT + GC
+ EH + threads 着手で更にドリフトが拡大する。具体的:

- `src/feature/` の計画は逆方向化 (実装は `src/interp/ext_2_0/` に流入)
- `src/runtime/` の 11 ファイル計画は 2 ファイル止まり、Module /
  Instance / Store / Engine 等の概念が `interp/` + `frontend/` +
  `c_api/` に散在
- `src/c_api/instance.zig` 2216 LOC は §A2 hard-cap 違反、起票なし
- `src/jit/` + `src/jit_arm64/` のフラット並列は §A3 を知らないと読めない
- `src/util/` は `dbg + leb128` のみで意味の薄い vague-bucket
- `src/c_api_lib.zig` 直下 + `src/c_api/` ディレクトリ並列の異常

ROADMAP は計画時点の予測であり、実装過程で複数箇所が逸脱した。
ここで `src/` の最終形を再定義することで、Phase 8〜16 のドリフト
を予防する。

---

## 2. 設計原則

- **P-A 単一情報源**: 各概念は `src/` 配下の一箇所に住む
- **P-B Pipeline 可視**: parse → validate → IR → analyze →
  {interp | codegen} → execute がディレクトリ階層から読める
- **P-C Engine sibling parity**: 実行エンジン (interp /
  codegen-arm64 / codegen-x86_64 / codegen-aot) は互いに
  sibling、1 階層の同列に置く
- **P-D Vertical slicing for VM-capability extensions**: 新 runtime
  state 型・新型システム軸・ABI 変更・JIT 出力形状の全体変更
  のいずれかを伴う subsystem は vertical 切り出し (`feature/<X>/`)
- **P-E Horizontal slicing for stateless opcode additions**: 新
  opcode を追加するが VM 能力モデルは変えない命令族は
  horizontal 切り出し (`instruction/wasm_X_Y/`)
- **P-F Naming non-redundancy**: 親ディレクトリ名はファイル名に
  再現しない。例外: package 代表ファイル
  (`runtime/runtime.zig`、`instance/instance.zig`) は許容
- **P-G Vague bucket prohibition**: `util/`, `helpers/`,
  `common/`, `misc/`, `lib/`, `core/` のような意味薄な親
  ディレクトリ名は禁止。`support/` は最小限の specific helper
  用に限定許容
- **P-H Future-state accommodation**: Phase 8〜16 で landing
  するもの (AOT / GC / EH / threads / stack_switching /
  Component Model 等) のディレクトリ slot を構造確定時に
  reserve する。中身は空 README で「Phase NN で実装」と明示
- **P-I Cross-cutting concerns get their own dir**: Diagnostic /
  tracing / logging のような cross-cutting concern は独立
  ディレクトリで扱う
- **P-J Build-flag mappable structure**: ディレクトリ階層は
  build flag (`-Dwasm=2.0`, `-Dengine=interp`, `-Daot=false`,
  `-Denable=gc` 等) と 1:1 mapping し、特定 flag が 1 ディレ
  クトリ subtree を build から除外できる形にする
- **P-K WASM/WASI 業界用語整合**: ディレクトリ名・ファイル名は
  WASM Core Spec / wasm-c-api / WASI / WebAssembly/<proposal-name>
  の業界用語を優先採用する。長さよりも明示性を優先、ただし業界
  慣用 (例: `gc`) と長過ぎ (例: `garbage_collection`) の閾値は
  spec 慣習に従う。**意味不明な省略 (例: `eh`, `p1`) は禁止、
  公式名・フル名を採用する**

---

## 3. WASM / 業界用語の採用方針

ディレクトリ・ファイル命名で参照する公式表現:

| 概念                               | 出典                                                     | 採用 zwasm 命名                                                                  |
|------------------------------------|----------------------------------------------------------|----------------------------------------------------------------------------------|
| Instructions (§5.4) — 8 categories | WASM Core Spec                                           | `instruction/wasm_X_Y/<category>.zig`                                            |
| Numeric / Reference / Vector / Parametric / Variable / Table / Memory / Control | §5.4 sub-section titles | wasm_1_0/ ファイル名軸                                                           |
| Runtime Structure (§4.2)           | WASM Core Spec                                           | `runtime/` 配下                                                                  |
| Module / Module Instance / Memory Instance / Table Instance / Global Instance / Function Instance / Store / Frame | §4.2 | `runtime/` + `runtime/instance/*.zig`                                            |
| Trap                               | §4.4                                                     | `runtime/trap.zig`                                                               |
| Engine / Store / Module / Instance / Trap / Func / Memory / Table / Global / Val | wasm-c-api `wasm.h`         | `runtime/{engine, store, module, value, trap}.zig` + `runtime/instance/*.zig`    |
| WASI preview1                      | WASI 0.1 spec                                            | `wasi/preview1.zig` (公式名フル展開)                                             |
| Sign Extension Operations          | proposal: WebAssembly/sign-extension-ops                 | `instruction/wasm_2_0/sign_extension.zig`                                        |
| Non-trapping Float-to-Int          | proposal: WebAssembly/nontrapping-float-to-int-conversions | `instruction/wasm_2_0/nontrap_conversion.zig`                                    |
| Multi-value                        | proposal: WebAssembly/multi-value                        | `instruction/wasm_2_0/multi_value.zig`                                           |
| Bulk Memory                        | proposal: WebAssembly/bulk-memory-operations             | `instruction/wasm_2_0/bulk_memory.zig`                                           |
| Reference Types                    | proposal: WebAssembly/reference-types                    | `instruction/wasm_2_0/reference_types.zig`                                       |
| SIMD-128                           | proposal: WebAssembly/simd                               | `feature/simd_128/` (vertical)                                                   |
| Garbage Collection                 | proposal: WebAssembly/gc                                 | `feature/gc/` (`gc` は業界慣用 2 文字略、許容)                                   |
| Exception Handling                 | proposal: WebAssembly/exception-handling                 | `feature/exception_handling/` (フル名)                                           |
| Tail Call                          | proposal: WebAssembly/tail-call                          | `feature/tail_call/`                                                             |
| Function References                | proposal: WebAssembly/function-references                | `feature/function_references/` (フル名)                                          |
| memory64                           | proposal: WebAssembly/memory64                           | `feature/memory64/`                                                              |
| Threads                            | proposal: WebAssembly/threads                            | `feature/threads/` (reserved)                                                    |
| Stack Switching                    | proposal: WebAssembly/stack-switching                    | `feature/stack_switching/` (reserved)                                            |
| Component Model                    | proposal: WebAssembly/component-model                    | `feature/component/` (reserved)                                                  |
| Extended Const                     | proposal: WebAssembly/extended-const                     | `instruction/wasm_3_0/extended_const.zig` (新 opcode なし、doc comment のみ)     |
| Relaxed SIMD                       | proposal: WebAssembly/relaxed-simd                       | `feature/simd_128/relaxed.zig` (SIMD subsystem に統合)                           |
| Wide Arithmetic                    | proposal: WebAssembly/wide-arithmetic                    | `instruction/wasm_3_0/wide_arith.zig`                                            |
| Custom Page Sizes                  | proposal: WebAssembly/custom-page-sizes                  | `instruction/wasm_3_0/custom_page_sizes.zig`                                     |

ファイル名は WebAssembly/<proposal-name> repo 名の `-` を `_` に
変換した形を基本とする (snake_case 規約 §A11 適合)。

---

## 4. Decision — 採用構造

```
src/
│
├── parse/                      WASM Binary Format → 構造化 Module
│   ├── parser.zig              top-level parse driver
│   ├── sections.zig            type / function / import / global / table / data / element decoders
│   └── ctx.zig                 ParseContext (was parse_ctx.zig)
│
├── validate/                   Module 静的検証 (型スタック + 制御スタック)
│   └── validator.zig           validation rules (production > 800 LOC のため _tests.zig 分離許容)
│
├── ir/                         Zwasm Intermediate Representation + 解析パス
│   ├── zir.zig                 ZirOp catalogue + ZirInstr + ZirFunc (ROADMAP §4.2)
│   ├── dispatch.zig            DispatchTable type (was ir/dispatch_table.zig; redundant prefix 解消)
│   ├── lower.zig               wasm-op → ZirOp lowering (was frontend/lowerer.zig)
│   ├── verifier.zig            ZIR.verify() — 解析パス後ごとに呼ぶ
│   └── analysis/
│       ├── loop_info.zig       branch_targets / loop_headers / loop_end
│       ├── liveness.zig        per-vreg live ranges
│       └── const_prop.zig      限定的 const folding
│
├── runtime/                    WASM Spec §4.2 "Runtime Structure" — host 側状態型
│   ├── runtime.zig             Runtime 中央 handle: { io, gpa, engine, stores, config, vtable }
│   ├── engine.zig              Engine (wasm-c-api wasm_engine_t)
│   ├── store.zig               Store (wasm-c-api wasm_store_t; Instance 集合)
│   ├── module.zig              parsed Module (frontend/parser.zig の Module を移管)
│   ├── value.zig               Value extern union (i32 / i64 / f32 / f64 / funcref / externref)
│   ├── trap.zig                Trap (zwasm-internal; api/trap_surface.zig が wasm_trap_t marshal)
│   ├── frame.zig               Frame (call frame: locals + operand stack + return PC + parent)
│   └── instance/               WASM Spec §4.2 "Instances" — instance 化された runtime state
│       ├── instance.zig        Instance (instantiated module、container; c_api/instance.zig 2216 LOC を分割移管)
│       ├── memory.zig          Memory Instance + memory.copy / fill / init helpers
│       ├── table.zig           Table Instance + table.copy / init / fill helpers
│       ├── global.zig          Global Instance
│       ├── func.zig            FuncEntity (ADR-0014 §6.K.1: instance-bearing funcref)
│       ├── element.zig         Element segment state (table.init / elem.drop の対象)
│       └── data.zig            Data segment state (memory.init / data.drop の対象)
│
├── instruction/                WASM Spec §5.4 命令カテゴリ — stateless opcode 実装
│   ├── wasm_1_0/               Wasm 1.0 MVP (§5.4 命令カテゴリ軸)
│   │   ├── numeric_int.zig     i32 / i64 const + ALU + cmp + bit
│   │   ├── numeric_float.zig   f32 / f64 const + arith + cmp
│   │   ├── numeric_conversion.zig wrap / extend / trunc / convert / promote / demote / reinterpret
│   │   ├── parametric.zig      drop / select / select_typed
│   │   ├── variable.zig        local.get / set / tee + global.get / set
│   │   ├── memory.zig          load / store + memory.size / grow (基本; 64-bit は feature/memory64/)
│   │   └── control.zig         unreachable / nop / block / loop / if / else / end / br / br_if / br_table / return / call / call_indirect
│   │
│   ├── wasm_2_0/               Wasm 2.0 released (proposal 名軸; 1.0 と異なる軸は spec の歴史を反映)
│   │   ├── sign_extension.zig  i32.extend8_s / 16_s / i64.extend{8, 16, 32}_s
│   │   ├── nontrap_conversion.zig i32 / i64 .trunc_sat_f32 / f64 _s / _u
│   │   ├── multi_value.zig     blocktype 拡張 (mostly metadata)
│   │   ├── bulk_memory.zig     memory.copy / fill / init / data.drop / table.copy / init / elem.drop
│   │   └── reference_types.zig ref.null / is_null / func / table.get / set / size / grow / fill
│   │
│   └── wasm_3_0/               Wasm 3.0 simple ops (state-less)
│       ├── extended_const.zig  新 opcode なし (const expression 拡張のみ); doc comment のみのファイルとして存在
│       ├── wide_arith.zig      i64.add128 / sub128 / mul_wide_s / _u
│       └── custom_page_sizes.zig memory.discard + memarg page-size variant
│
├── feature/                    VM 能力拡張 — 新 state / 新型システム / ABI 変更を伴う subsystem
│   ├── simd_128/               SIMD-128 (Wasm 2.0; relaxed_simd は本サブツリーに統合)
│   │   ├── register.zig        DispatchTable への register entry (`pub fn register`)
│   │   ├── ops.zig             v128 ops (load / store / splat / lane / arith / cmp / conv)
│   │   ├── register_class.zig  v128 reg class (NEON / SSE4.1; GPR / FPR から独立)
│   │   ├── lane.zig            lane shuffle / extract / replace primitives
│   │   ├── nan_propagation.zig f32x4 / f64x2 NaN propagation per Wasm spec
│   │   ├── relaxed.zig         relaxed-simd ops (Wasm 3.0 追加分)
│   │   ├── arm64.zig           NEON emit
│   │   └── x86_64.zig          SSE4.1 emit
│   │
│   ├── gc/                     Wasm 3.0 — マネージド・ヒープ
│   │   ├── register.zig
│   │   ├── ops.zig             struct.* / array.* / ref.test / ref.cast / ref.i31 / i31.get_*
│   │   ├── heap.zig            HeapHeader + 8-byte aligned tagged pointer
│   │   ├── arena.zig           初期 arena tier (bulk free; 後で mark_sweep に統合)
│   │   ├── mark_sweep.zig      mark-sweep collector
│   │   ├── roots.zig           root set (operand stack + locals + globals + tables)
│   │   ├── type_hierarchy.zig  struct / array subtyping + recursive types
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── exception_handling/     Wasm 3.0 — 構造化 non-local 制御
│   │   ├── register.zig
│   │   ├── ops.zig             try_table / throw / throw_ref
│   │   ├── tag.zig             Exception tag (型 + signature)
│   │   ├── unwind.zig          Frame unwinding 機構
│   │   ├── landing_pad.zig     JIT landing pad metadata
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── tail_call/              Wasm 3.0 — 末尾呼び出し最適化
│   │   ├── register.zig
│   │   ├── ops.zig             return_call / return_call_indirect / return_call_ref
│   │   ├── frame_replace.zig   interp 側 frame 置換ロジック
│   │   ├── arm64.zig           epilogue 別変種 emit
│   │   └── x86_64.zig
│   │
│   ├── function_references/    Wasm 3.0 — 型付き関数参照 + null tracking
│   │   ├── register.zig
│   │   ├── ops.zig             call_ref / ref.as_non_null / br_on_null / br_on_non_null
│   │   ├── typed_ref.zig       typed function reference 型表現
│   │   ├── null_tracking.zig   validator 拡張 (nullable vs non-null)
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── memory64/               Wasm 3.0 — 64-bit memory addressing
│   │   ├── register.zig
│   │   ├── ops.zig             memarg.is_64 dispatched load / store / grow / size
│   │   ├── bounds_check_64.zig 64-bit bounds check primitive
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── threads/                Phase 4 proposal、reserved
│   │   └── README.md
│   │
│   ├── stack_switching/        Phase 3 proposal、reserved
│   │   └── README.md
│   │
│   └── component/              Component Model、reserved
│       └── README.md
│
├── engine/                     engine sibling parity (interp / codegen-{arm64, x86_64, aot})
│   ├── runner.zig              公開エントリ: ZirFunc を invoke する薄い facade。runtime.vtable 経由で interp / codegen に dispatch (was jit/run_wasm.zig + interp/mvp.invoke)
│   │
│   ├── interp/                 threaded-code interpreter
│   │   ├── loop.zig            dispatch loop (was dispatch.zig; ir/dispatch.zig との同名衝突回避)
│   │   └── trap_audit.zig      trap detection audit machinery
│   │
│   └── codegen/                JIT + AOT 共通の compiler pipeline
│       ├── shared/             arch-neutral codegen infrastructure
│       │   ├── regalloc.zig    greedy-local + spill (ADR-0018)
│       │   ├── reg_class.zig   GPR / FPR / SIMD / inst_ptr / vm_ptr / simd_base 分類
│       │   ├── linker.zig      BL fixup patcher
│       │   ├── compile.zig     per-function compile orchestrator (was jit/compile_func.zig)
│       │   ├── entry.zig       JIT-compiled code への呼び出しゲート
│       │   ├── prologue.zig    arch-iface trait + concrete dispatch
│       │   └── jit_abi.zig     JitRuntime ABI offsets (ADR-0017; was runtime/jit_abi.zig)
│       │
│       ├── arm64/              ARM64 emit (Mac aarch64)
│       │   ├── emit.zig        orchestrator (post-7.5d ≤ 1000 LOC)
│       │   ├── op_const.zig    7.5d sub-b 9-module 分割の 1
│       │   ├── op_alu.zig      i32 / i64 ALU + comparisons + shifts
│       │   ├── op_memory.zig   load / store + memory.size / grow + bounds check
│       │   ├── op_control.zig  block / loop / br / br_table / if / else / end + D-027 merge logic
│       │   ├── op_call.zig     call + call_indirect + arg / result marshal
│       │   ├── bounds_check.zig f32 / f64 → i32 / i64 bounds check primitives
│       │   ├── inst.zig        instruction encoder primitives
│       │   ├── abi.zig         AAPCS64 calling convention tables
│       │   ├── prologue.zig    ARM64 prologue layout helper (ADR-0021 sub-a)
│       │   └── label.zig       Label / Fixup / FixupKind / merge_top_vreg
│       │
│       ├── x86_64/             x86_64 emit (Linux / Win) — Phase 7.6+ で実装
│       │   ├── emit.zig        orchestrator (mirrors arm64/ shape)
│       │   ├── op_const.zig
│       │   ├── op_alu.zig
│       │   ├── op_memory.zig
│       │   ├── op_control.zig
│       │   ├── op_call.zig
│       │   ├── bounds_check.zig
│       │   ├── inst.zig
│       │   ├── abi.zig         System V (Linux) + Win64 (Windows) calling conventions
│       │   ├── prologue.zig
│       │   └── label.zig
│       │
│       └── aot/                AOT (Phase 8+ skeleton; Phase 12 finalisation)
│           ├── format.zig      .cwasm header + serialization format
│           └── linker.zig      AOT relocation
│
├── wasi/                       WASI preview1 implementation
│   ├── preview1.zig            preview1 entry + register (was p1.zig; 公式名フル展開)
│   ├── host.zig                capability table (preopens / args / environ via std.process.Init)
│   ├── fd.zig                  fd_read / write / close / seek / tell + path_open + fdstat
│   ├── clocks.zig              clock_time_get + random_get + poll_oneoff
│   └── proc.zig                proc_exit + args_get / sizes_get + environ_get / sizes_get
│
├── api/                        wasm-c-api 互換 C ABI (was c_api/)
│   ├── wasm.zig                wasm.h impl: wasm_engine_* / wasm_store_* / wasm_module_* / wasm_instance_* / wasm_func_*
│   ├── wasi.zig                wasi.h impl (wasm-c-api 互換 WASI 拡張)
│   ├── zwasm.zig               zwasm.h ext: allocator inj / fuel / timeout / cancel / fast invoke
│   ├── vec.zig                 wasm_*_vec_t lifecycle helpers
│   ├── trap_surface.zig        Trap → wasm_trap_t marshal
│   ├── cross_module.zig        cross-module funcref dispatch
│   └── lib_export.zig          dylib symbol export surface (was c_api_lib.zig)
│
├── cli/                        CLI subcommands
│   ├── run.zig                 zwasm run <wasm-file>
│   ├── compile.zig             zwasm compile (Phase 12)
│   ├── validate.zig            zwasm validate
│   ├── inspect.zig             zwasm inspect
│   ├── features.zig            zwasm features
│   ├── wat.zig                 zwasm wat (Phase 11)
│   ├── wasm.zig                zwasm wasm (Phase 11)
│   └── diag_print.zig          Diagnostic を terminal output に整形
│
├── platform/                   OS abstractions
│   ├── jit_mem.zig             RWX memory: mmap (POSIX) / VirtualAlloc (Windows)
│   ├── signal.zig              Phase 7+: SIGSEGV → trap conversion
│   ├── fs.zig                  Phase 11: WASI fs adapter
│   └── time.zig                WASI 0.1 clock adapter
│
├── diagnostic/                 cross-cutting (Ousterhout deep module)
│   ├── diagnostic.zig          threadlocal Diag + setDiag / clearDiag (was runtime/diagnostic.zig)
│   └── trace.zig               Phase 7+: trace ringbuffer per ADR-0016 M3
│
├── support/                    最小限の specific helper
│   ├── dbg.zig                 dev-only logger (現状名維持; 「debug print 専用」の意図を保つ)
│   └── leb128.zig              encoding helper (parse + codegen/aot から使う neutral 位置)
│
└── main.zig                    CLI entry (Juicy Main: std.process.Init を受ける)
```

各 `feature/<X>/register.zig` は `pub fn register(*DispatchTable)` を
expose する。中央の DispatchTable に当該 feature の opcode 実装片
(parser hook / validator hook / interp handler / arm64 emit / x86_64
emit) を register する。

各 `instruction/wasm_X_Y/<category>.zig` は `pub fn register(*DispatchTable)`
を持ち、当該命令カテゴリの実装片を register する。

`extended_const.zig` のような新 opcode を追加しない proposal の
ファイルは、`//!` doc comment のみのファイルとして存在する
(中身は const expression validator の拡張のみで、新 ZirOp は
無いため)。Zig は declaration ゼロのファイルを許容する。

---

## 5. Build flag mapping

ディレクトリ構造と build flag の 1:1 mapping (P-J 対応):

| Build flag                | 制御対象ディレクトリ                                                 |
|---------------------------|----------------------------------------------------------------------|
| `-Dwasm=1.0`              | `instruction/wasm_2_0/`, `instruction/wasm_3_0/`, `feature/{simd_128, gc, exception_handling, tail_call, function_references, memory64}/` を build から除外 |
| `-Dwasm=2.0`              | `instruction/wasm_3_0/`, `feature/{gc, exception_handling, tail_call, function_references, memory64}/` を除外 (simd_128 は 2.0 に含む) |
| `-Dwasm=3.0` (default)    | 全 instruction/ + 上記 active feature/ を含む                        |
| `-Dengine=interp`         | `engine/codegen/` ツリー全体除外 (interpreter-only バイナリ)         |
| `-Dengine=jit`            | `engine/interp/` 除外                                                |
| `-Dengine=both` (default) | 全 engine 含む                                                       |
| `-Daot=true`              | `engine/codegen/aot/` を含む (Phase 8+)                              |
| `-Daot=false` (現状 default) | `engine/codegen/aot/` 除外                                       |
| `-Denable=<feature>`      | 個別 `feature/<X>/` の含む / 除外 (per-feature 細粒度切替)           |
| `-Dwasi=preview1` (default) | `wasi/` + `platform/{fs, time}.zig` 含む                           |
| `-Dwasi=none`             | `wasi/` 除外                                                         |
| `-Dapi=c` (default)       | `api/` 含む                                                          |
| `-Dapi=none`              | `api/` 除外 (ライブラリ embed 用途)                                  |

各 `feature/<X>/register.zig` は build flag を comptime 読み込み、
無効化時は `register(*DispatchTable)` を no-op にする。
`build.zig` 側の対応 (各 module の comptime exclude / addModule
分岐) は実装時に確定する。

---

## 6. ROADMAP 修正

本 ADR の commit と同期して以下の ROADMAP セクションを書き換え
(§18.2 four-step amendment):

| ROADMAP セクション      | 変更内容                                                                                                                                  |
|-------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| §4.1 (Four-zone layered) | path 全書き換え: `interp / jit / jit_arm64 / wasi / c_api` → `engine/{interp, codegen}, wasi, api` 等                                     |
| §4.2 (ZIR catalogue)    | 変更なし (`ir/zir.zig`)                                                                                                                   |
| §4.3 (engine pipeline)  | pipeline 図を新 path で書き直し                                                                                                           |
| §4.4 (wasm-c-api ABI)   | `c_api/*` → `api/*`                                                                                                                       |
| §4.5 (feature modules)  | feature/ vs instruction/ の二段論を本 ADR で確定、§4.5 全文を書き換え                                                                     |
| §4.7 (Runtime handle)   | path: `interp/mod.zig:Runtime` → `runtime/runtime.zig:Runtime`                                                                            |
| §4.10 (GC subsystem)    | `runtime/gc/` → `feature/gc/` (vertical 集約)                                                                                             |
| §5 (directory layout)   | 本 ADR §4 のツリーで全置換                                                                                                                |
| §A1 (Zone deps)         | zone は 4 のまま、内訳 path 書き換え                                                                                                      |
| §A2 (file size)         | tests 分離 rubric を追記: 「production code 単体 ≤ 800 LOC は inline test 必須。production > 800 LOC かつ tests 込み > 1000 LOC は `<file>_tests.zig` 分離可。production > 2000 LOC は §A2 hard-cap 違反として ADR 起票対象」 |
| §A3 (cross-arch ban)    | `jit_arm64 ↔ jit_x86` → `engine/codegen/arm64 ↔ engine/codegen/x86_64`                                                                    |
| §A11 (snake_case)       | 維持                                                                                                                                      |
| §14 (forbidden)         | 維持                                                                                                                                      |
| §15 (future decision)   | Phase 7 末の Phase 8 / 11 / 13 ordering 議論は本 ADR 採用後に再評価                                                                       |

ROADMAP §A2 amend の rubric は本 ADR 内で確定し、`scripts/file_size_check.sh`
の振る舞いとも整合させる (production / tests の境界判定は今後の
スクリプト改修で対応)。

---

## 7. Implementation order

依存順の作業項目を列挙する。各項目間は依存があるため順序は固定。
commit 単位の分割や 3-host gate 通過のタイミングは実施時に判断
する (項目数 = commit 数 ではない)。

1. 本 ADR 確定 + ROADMAP §4.1 / §4.2 / §4.3 / §4.4 / §4.5 / §4.7
   / §4.10 / §5 / §A1 / §A2 / §A3 amend
2. `runtime/` の既存 2 ファイル (`diagnostic.zig`, `jit_abi.zig`)
   を退去:
   - `runtime/diagnostic.zig` → `diagnostic/diagnostic.zig`
   - `runtime/jit_abi.zig` → `engine/codegen/shared/jit_abi.zig`
3. `runtime/runtime.zig` 新設、`interp/mod.zig` から Runtime
   struct を分離移管。`interp/mod.zig` は薄い entry になる
4. `runtime/{module, value, trap, frame, engine, store}.zig`
   新設: 各概念を frontend / interp / c_api から抽出
5. `runtime/instance/instance.zig` 新設: `c_api/instance.zig`
   2216 LOC を分割し、Instance struct + 関連ロジックを移管。
   wasm-c-api binding 部分のみ `api/wasm.zig` に残す
6. `runtime/instance/{memory, table, global, func, element, data}.zig`
   新設: instance 配下の各 instance 種別を抽出
7. `parse/`, `validate/`, `ir/analysis/` 新設: 旧 `frontend/`
   を解体し、parser / sections / ctx を `parse/` へ、validator
   を `validate/` へ、lowerer を `ir/lower.zig` へ、loop_info /
   liveness / const_prop を `ir/analysis/` へ
8. `instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/` 新設、旧
   `interp/{mvp_*.zig, ext_2_0/}` を移動。`extended_const.zig`
   は doc-comment-only のファイルとして配置
9. `feature/` の active 6 (`simd_128, gc, exception_handling,
   tail_call, function_references, memory64`) + reserved 3
   (`threads, stack_switching, component`) を作成。reserved
   は README.md のみ。SIMD-128 は既存 ext_2_0 の SIMD 関連を
   集約 (現状コードはほぼ無いため雛形 register.zig だけ用意)
10. `engine/{runner.zig, interp/, codegen/{shared, arm64, x86_64, aot}/}`
    新設: 旧 `jit/*` を `engine/codegen/shared/` へ、旧
    `jit_arm64/*` を `engine/codegen/arm64/` へ、旧
    `interp/{dispatch.zig, trap_audit.zig}` を
    `engine/interp/{loop.zig, trap_audit.zig}` へ移動。
    `engine/runner.zig` を新設し旧 `jit/run_wasm.zig` +
    `interp/mvp.zig:invoke` を統合
11. `api/` 新設、旧 `c_api/*` を移動。`c_api/wasm_c_api.zig` →
    `api/wasm.zig`、`c_api/instance.zig` 残部 (binding 層) は
    `api/wasm.zig` に統合または `api/instance_binding.zig`。
    `c_api_lib.zig` → `api/lib_export.zig`
12. `cli/` 整理: `cli/diag_print.zig` 維持、Phase 11/12 で
    landing する `compile.zig` / `wat.zig` / `wasm.zig` の slot
    のみ作成 (中身は将来 Phase で実装)
13. `wasi/p1.zig` → `wasi/preview1.zig` rename + 内部の参照
    更新
14. `platform/` 拡張: `signal.zig` / `fs.zig` / `time.zig` の
    slot 作成 (中身は将来 Phase で実装)
15. `diagnostic/`, `support/` 確立: `util/dbg.zig` →
    `support/dbg.zig`、`util/leb128.zig` → `support/leb128.zig`、
    `runtime/diagnostic.zig` → `diagnostic/diagnostic.zig`、
    `cli/diag_print.zig` は cli/ に残置
16. emit.zig 9-module 分割 (ADR-0021 row 7.5d sub-b、新パス
    `engine/codegen/arm64/` 配下で実施)
17. handover.md sync + 関連既存 ADR (ADR-0017 / 0018 / 0019 /
    0021) の path citation 更新
18. 旧パスへの参照が残っていないか全体スイープ + zone_check.sh
    の対応 path 更新

各項目で 3-host gate (Mac native + OrbStack Ubuntu + windowsmini
SSH) を必要箇所で通過させる。big-bang 厳禁。

---

## 8. Consequences

### Positive

- ROADMAP §4.5 / §5 と実装の乖離が解消
- `c_api/instance.zig` 2216 LOC §A2 違反が discharge
- emit.zig 9-module 分割が新パス上で自然に landing (ADR-0021 row 7.5d sub-b)
- Phase 8〜16 の future state すべてに reserved slot あり (`threads, stack_switching, component, aot, signal, fs, time`)
- WASM 業界用語との整合により、新規参入者が WASM Spec / proposal repo を見ながら zwasm を読める
- Build flag (`-Dwasm`, `-Dengine`, `-Daot`, `-Denable`, `-Dwasi`, `-Dapi`) と subtree が 1:1 mapping
- `runtime/{runtime, module, instance/instance}.zig` の WASM Spec §4.2 直訳構造により、Runtime / Module / Instance の住所が一意

### Negative

- 全体的なディレクトリ構造変更により、既存 ADR (ADR-0017 / 0018 / 0019 / 0021) の path citation を全更新する必要
- `feature/` 配下の reserved slot (`threads, stack_switching, component`) は README.md のみで実体無し、誤解の素にならないよう README は明示的に記述する
- `instruction/wasm_1_0/` が WASM Spec §5.4 命令カテゴリ軸、`instruction/wasm_{2,3}_0/` が proposal 名軸という命名軸の混在 (spec の歴史的経緯による必然)

### Neutral / 関連

- `feature/<X>/register.zig` の register は `pub fn register(*DispatchTable)`。各 .zig ファイル冒頭の `//!` doc comment で意図を明示する規約
- ROADMAP §A2 amend で `_tests.zig` 分離 rubric を確定。`scripts/file_size_check.sh` の振る舞い更新は別タスク
- `feature/component/` (Component Model) は post-v0.2.0 で実装、v0.1.0 では reserve のみ
- 旧 `c_api/instance.zig` 2216 LOC の分割境界は実装時に判断: Instance 本体 (instantiation logic) → `runtime/instance/instance.zig`、wasm-c-api binding 層 → `api/wasm.zig` または `api/instance_binding.zig`

---

## References

- WebAssembly Core Specification §4.2 (Runtime Structure)
- WebAssembly Core Specification §5.4 (Instructions)
- wasm-c-api `wasm.h` (`include/wasm.h`)
- WASI preview1 spec
- WebAssembly/<proposal-name> repos (WebAssembly/sign-extension-ops, WebAssembly/multi-value, WebAssembly/gc, WebAssembly/exception-handling, WebAssembly/tail-call, WebAssembly/function-references, WebAssembly/memory64, WebAssembly/threads, WebAssembly/stack-switching, WebAssembly/component-model, WebAssembly/extended-const, WebAssembly/relaxed-simd, WebAssembly/wide-arithmetic, WebAssembly/custom-page-sizes)
- LLVM `lib/CodeGen/` 命名慣習
- Cranelift `cranelift/codegen/` 命名慣習
- ADR-0014 (FuncEntity instance-bearing funcref)
- ADR-0017 (JitRuntime ABI)
- ADR-0018 (regalloc reserved set + spill)
- ADR-0019 (x86_64 を Phase 7 に)
- ADR-0021 (emit-split sub-gate)
- ROADMAP §4 / §5 / §A1 / §A2 / §A3 / §14

## Revision history

| Date       | Commit       | Why-class | Summary                       |
|------------|--------------|-----------|-------------------------------|
| (本 commit) | `<backfill>` | initial   | ディレクトリ構造・命名の正規化、Q1〜Q10 議論結論統合。 |
