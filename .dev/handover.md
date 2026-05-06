# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/phase8_transition_gate.md` — 🔒 Phase 7→8 hard gate (load-bearing).
3. `.dev/decisions/0019_x86_64_in_phase7.md` / 0021 / 0023 / 0025 / 0026 / 0027 / 0028 — recent ADRs.
4. `.dev/debt.md` — discharge `Status: now` rows; review `blocked-by` triggers.
5. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
6. `.dev/optimisation_log.md` — F-NNN / R-NNN / O-NNN ledger.

## Current state — Phase 7 / §9.7 / 7.5 IN-PROGRESS

直近 commit (HEAD = `a69ac4e`):

- `a69ac4e` §9.7 / 7.5-spec-assertion-driver-l (D-034: i32 unary/cmp/bitcount/rot; 16 ops)
- `ca80c4a` §9.7 / 7.5-spec-assertion-driver-k (D-034: emitI32Binary; 9 ops)
- `5f19285` §9.7 / 7.5-spec-assertion-driver-j (globals; 95/0/0)
- `4e86b45` §9.7 / 7.5-spec-assertion-driver-i (scratch memory; 91/0/0)

**Active task**: spec-assertion-driver-l landed。i32 ALU
全範囲が spill-aware に: emitI32Compare (10 ops) + Eqz + Clz +
Ctz + Popcnt + Rotr + Rotl (合計 16 ops, -k と合わせて 25 ops)。
1027 tests / spec_assert 95/0/0 / spec-jit-compile 10/2 据え置き。

**NEXT** = `7.5-spec-assertion-driver-m` (D-034 chain 続き — i64
family: emitI64Binary / Compare / Eqz / Shift / Rotr / Rotl /
Clz / Ctz / Popcnt を spill-aware 化。同 stage 規約)。
subsequent: -n (memory / convert / call), -o (regalloc/
liveness count desync 根本調査)。

> **🔒 Phase 7 → 8 hard gate** が §9.7 / 7.13 に登録済。
> Autonomous /continue loop は 7.13 row を発見した時点で
> ScheduleWakeup を skip して user に surface する規律
> ([`phase8_transition_gate.md`](phase8_transition_gate.md) +
> `.claude/skills/continue/SKILL.md` §"Exception — hard
> human-in-loop transition gates")。Detection は 2 checkpoint
> (Resume Procedure Step 2 + Step 7 re-target) で発火。
> Gate checklist は (1) functional completion / (2) debt
> reconciliation / (3) AOT/Wasm 3.0/WASI/SIMD horizon の
> design cleanliness / (4) optimisation_log triage /
> (5) meta_audit + strategic review の 5 section。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`。

## §9.7 / 7.7 chunk progress

7.5 sub-chunks (post-survey + jit-compile-runner):

| # | Chunk | Status |
|---|---|---|
| 7.5-jit-compile-runner | corpus walker; `zig build test-spec-jit-compile`; 1/12 pass | DONE (217c214) |
| 7.5-empty-module-fix | `compileWasm` + `linker.link` が 0-function modules を accept | DONE (818e5a8; 2/12) |
| 7.5-multi-arg-entry | ARM64 X1..X7 i32 params (≤ 7 i32 のみ; i64/f/* + 8th+ stack-arg は defer) | DONE (e0af079; 3/12) |
| 7.5-investigate-fails | 残り 9 fails を per-fixture で原因分類 (drop / unreachable / return / FP-i64 result / mixed-type params など) | DONE (root-causes 調査完了) |
| 7.5-drop-unreachable | drop + unreachable + B-fixup patcher 拡張 | DONE (461cc1a; 5/12) |
| 7.5-jit-compile-diag | compileWasm の per-func stderr log | DONE (7745172) |
| 7.5-arm64-end-fp-i64 | ARM64 end-handler は既に FP-aware (line 525-553); 不要と判明 | OBSOLETE |
| 7.5-nop | ARM64 emit に nop handler 追加 | DONE (d286cbc; 5/12) |
| 7.5-i64-params | arm64/emit.zig:134 の i64 param 受け入れ + prologue STR X (64-bit) | DONE (953eedf; 5/12; D-033 filed) |
| 7.5-fp-params | f32/f64 params (V0..V7 → STR S/D scalar マーシャル) | DONE (3253a68; 5/12) |
| 7.5-block-result-deadcode | liveness の pop site を tolerant 化 (dead-code zone で no-op) | DONE (67eb894; OSU 解消) |
| 7.5-return-op | wasm `return` op (mid-function early exit; B-fixup → epilogue) | DONE (8874bbb; 6/12) |
| 7.5-emit-deadcode | `dead_code` flag in emit; skip ops in poly-stack zone; reset on end/else | DONE (764f212; 6/12) |
| 7.5-diag-op | unsupported op tag + param reject reason を stderr に出力 | DONE (962a24c) |
| 7.5-select-op | wasm `select` + `select_typed` (CMP + CSEL Wd) | DONE (4440622; 6→7) |
| 7.5-diag-spill | gpr.zig の spill reject path に diag (将来用 infra) | DONE (75668e1) |
| 7.5-investigate-unwind | unwind.0 func[1] の UnsupportedOp 起点を per-op で trace | DONE (br-to-function fix で解決) |
| 7.5-br-to-function | `br N` / `br_if N` で depth==labels.len を return として扱う | DONE (668c092) |
| 7.5-br-table-to-function | `br_table` の per-case で function-depth case を return として扱う | DONE (7aa7475; 7→8) |
| 7.5-investigate-labels | op_control diag で真因 surface (else without if_then; merge stack short) | DONE (4b275ed) |
| 7.5-deadcode-labels-bookkeeping | dead_code 中の placeholder labels + tolerant emitElse / emitEndIntra | DONE (6fa1c6d; 8→10) |
| 7.5-spill-enable-or-pool | SlotOverflow @ func[9] params=5 の spill vs pool-extension 判定 | DEFERRED (D-034; spill-aware op handlers refactor が必要) |
| 7.5-local-type-aware | local.get/set/tee の width を declared type 別に (D-033 discharge) | pending |
| 7.5-spec-assertion-driver-a | wast2json regen + callI32_i32 + spec_assert_runner; forward.wast 4/4 PASS | DONE (503b5ee) |
| 7.5-spec-assertion-driver-b | 2-arg i32 (callI32_i32i32) + handcrafted_2arg fixture (10/0/0) | DONE (5cbf28a) |
| 7.5-spec-assertion-driver-c | i64 result (callI64*); handcrafted_i64; D-033 surface | DONE (c347bcd) |
| 7.5-spec-assertion-driver-d | assert_trap directive + handcrafted_trap (17/0/1) | DONE (b8ebe8e) |
| 7.5-spec-assertion-driver-e | regen に assert_trap + i64 受容; unreachable.wast 取込 (80/0/1) | DONE (a6cd9f3) |
| 7.5-spec-assertion-driver-f | D-033 discharge (local.get/set/tee width-aware); 81/0/0 | DONE (ff7df89) |
| 7.5-spec-assertion-driver-g | FP locals (f32/f64) の V-reg encoders + local.get/set/tee 拡張 | DONE (7049a2c) |
| 7.5-spec-assertion-driver-h | runner FP entry helpers + handcrafted_fp (87/0/0) | DONE (e581282) |
| 7.5-spec-assertion-driver-i | 64KB scratch memory + handcrafted_mem; memory.size/load/store; 91/0/0 | DONE (4e86b45) |
| 7.5-spec-assertion-driver-j | globals support + per-fixture state reset (95/0/0) | DONE (5f19285) |
| 7.5-spec-assertion-driver-k | D-034: emitI32Binary spill-aware (9 ops) | DONE (ca80c4a) |
| 7.5-spec-assertion-driver-l | D-034 i32 unary/cmp/bitcount/rot (16 ops) | DONE (a69ac4e) |
| 7.5-spec-assertion-driver-m | D-034 i64 family handlers | **NEXT** |
| 7.5-spec-assertion-driver-n | D-034 memory / convert / call handlers | pending |
| 7.5-spec-assertion-driver-o | regalloc/liveness count desync 調査 (true SlotOverflow root) | pending |
| 7.5-trap-reason-channel | trap_flag を `enum TrapReason` に拡張 (assert_trap reason discrimination) | pending (ADR-0028 / Diagnostic M3) |

ADR-0019 phase plan post-7.6: 7.7 emit.zig, 7.8 spec gate (Linux
+ Windows hosts), 7.9/7.10 realworld, 7.11 3-way differential
🔒。ADR-0021 Revision history (sub-split + emit_test extraction)
は phase boundary batch update で。

## ADR-0025 (Zig host API) implementation chain

Phase A (design + ROADMAP §10 sync) DONE。Phase B-1〜B-5 (thin
facade + TypedFunc + WasiConfig + ImportEntry + examples) +
Phase D (migration doc) は post-7.5d sub-b 着手予定。詳細は
`.dev/decisions/0025_zig_library_surface.md` Revision history。
ADR-0025 self-review で 8 issues 起こり、すべて Revision history
row 2 で addressed (cross-module *Module → *Instance / facade の
zone placement / "constant overhead" / WASI prereq 等)。

## Open structural debt (pointers)

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後再評価。
- **D-026** env-stub host-func wiring (cross-module dispatch)。
- **D-029** x86_64 emitI32Binary `dst==rhs` reject — regalloc port 後に discharge。
- **D-030** x86_64 emit.zig / inst.zig op_*.zig 抽出 — 7.7 全 chunk landing 後。
- **D-031** runner runI32Export FP/i64 拡張 — JitRuntime memory init 後に at_limit 境界 fixture を再追加。
- emit.zig / inst.zig / emit_test.zig / api/instance.zig は soft-cap 圏内、hard-cap discharge 済。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (full history via `git log --oneline`)

- §9.7 / 7.5-deadcode-labels-bookkeeping (6fa1c6d): dead_code 中の block/loop/if が placeholder labels を push (no machine bytes; if_skip_byte=null marks no-CBZ)。emitElse は null skip_byte を tolerate して CBZ patch step を skip。emitEndIntra は dead else arm (pushed_vregs.len==1, top==merge_vreg) を検出して merge MOV を skip — merge target は既に top にいる。spec-jit-compile 8→10 (unreachable.0 / labels.0 both clear)。残 2 fails は両方とも SlotOverflow @ func[9] params=5。
- §9.7 / 7.5-investigate-labels (4b275ed): op_control.zig の `emitElse` と `emitEndIntra` (merge stack underflow + merge-vreg mismatch) の reject に stderr diag を追加。spec-jit-compile が surface する真因: labels.0 func[15] の merge stack short (then arm の br + dead-code skip で merge vreg push 不発), unreachable.0 func[29] の "emitElse without matching if_then" (outer if_then が dead-code propagation で pop)。両方とも 7.5-emit-deadcode の labels-stack 整合性問題が起源。
- §9.7 / 7.5-br-table-to-function (7aa7475): `op_control.emitBranchToDepth` を `*EmitCtx` ベースに refactor + `depth == labels.len` を return として処理 (br/br_if と同形)。各 br_table case で独立に marshal + B-fixup を emit (run-time に発火するのは 1 case のみなので duplicate marshal でも correct)。spec-jit-compile 7→8 (unwind.0 clears via func[5..7] の `br_table 0`)。
- §9.7 / 7.5-br-to-function (668c092): emitBr / emitBrIf が `payload == labels.items.len` の場合 (Wasm spec §3.3.5 の implicit function-level block) を return として処理。EmitCtx に `return_fixups: *List(u32)` を追加して既存の return-op 機構を共有。emitBrIf は CBZ skip + marshal + B epilogue + skip-target patch の 4-instruction shape。`>=` の reject を `>` に絞る。spec-jit-compile pass count 据え置き 7/12 だが unwind.0 が func[1] → func[5] (br_table at function-depth) に shift。
- §9.7 / 7.5-diag-spill (75668e1): arm64/gpr.zig の `resolveGpr` / `resolveFp` の `.spill` arm に stderr diag を追加。今回の残 fails では trigger されない (= spill path 由来ではない) と判明。次の chunk は inner reject path を直接 trace する方が速い。
- §9.7 / 7.5-select-op (4440622): arm64/emit に `select` + `select_typed` を追加。inst.zig に encCselW + encCselX。CMP + CSEL Wd で 32-bit i32 select を実装 (i64 + FP 変種は debt 化保留)。spec-jit-compile 6→7 (nop.0 clears)。
- §9.7 / 7.5-diag-op (962a24c): arm64/emit.zig に 3 つの stderr 診断を追加 (catch-all switch arm の op tag、prologue の > 7 params reject、prologue の non-int param-type reject)。spec-jit-compile-runner の出力で残り fails 4 件 (nop.0 / labels.0 / unreachable.0 / unwind.0) が `select` op 未実装で詰まっていることを確認。
- §9.7 / 7.5-emit-deadcode (764f212): arm64/emit.zig の main op-loop に `dead_code: bool` flag。br/return/unreachable で set; end/else で reset; その他の op は dead 中スキップ。Wasm spec §3.3 polymorphic-stack を validator から信頼。unreachable.0 の AllocationMissing が UnsupportedOp at func[29] に shift (より deep な functions が compile を通った)。Limitation: end/else で常に reset するため deeply-nested dead 領域では under-track の可能性 (conservative; 余分な byte だが unreachable なので無害)。
- §9.7 / 7.5-return-op (8874bbb): ARM64 emit に `return` op を追加。result marshal は end-handler の logic を inline 複製、その後 unconditional B placeholder を `return_fixups` に append。end-handler は frame teardown の byte offset (`epilogue_byte`) を capture し、return_fixups を全部 patch。trap stub は別 mechanism で従来通り。spec-jit-compile 5→6 (switch.0 clears via `return`)。
- §9.7 / 7.5-block-result-deadcode (67eb894): `ir/analysis/liveness.zig` の pop site (if cond / br_if cond / call args / generic op pops) を「sim_len > 0 のとき pop、empty なら no-op」に変更。Wasm spec §3.3 polymorphic-stack の dead-code 領域で validator が既に shape を保証しているため、liveness は dead pop を tolerant にしてよい。push 側の max-stack overflow check は実 buffer 制約のため error のまま維持。labels.0 / unreachable.0 の OperandStackUnderflow が解消し別 gap (UnsupportedOp / AllocationMissing) に shift。
- §9.7 / 7.5-fp-params (3253a68): arm64/emit.zig:134 の reject を f32/f64 にも開放; prologue を type-aware AAPCS64 multi-class marshalling に拡張 (independent int_arg_idx / fp_arg_idx counters)。inst.zig に `encStrSImm` / `encStrDImm` を追加。Mixed-sig (i32 f32 i64 f64) byte-level test を 1 つ追加。spec-jit-compile pass count 据え置き 5/12 だが local_get/set.0 が UnsupportedOp → SlotOverflow に shift (regalloc pool 5-param 枯渇; 別 chunk で対応)。
- §9.7 / 7.5-i64-params (953eedf): arm64/emit.zig:134 の reject を i64 にも開放; prologue の per-param STR を type-aware (i32→STR W / i64→STR X) に分岐。AAPCS64 §6.4 (i32 args の上位 32-bit は undefined) 準拠で i32 の STR W は load-bearing。f32/f64 はまだ UnsupportedOp。Test 修正 (旧「i64 param surfaces UnsupportedOp」を「STR X width 検証」に置換)。**D-033 filed**: local.get/set/tee は 32-bit 固定で i64 silent truncate — 7.5 完了前に discharge 必要。
- §9.7 / 7.5-nop (d286cbc): arm64 emit switch に nop ハンドラ (no-op body)。spec-jit-compile pass count は 5/12 据え置きだが nop.0 の最初の fail が func[2] → func[9] に深く移動 (incremental progress; 後続 chunk が次の op を解決すれば pass する可能性)。
- §9.7 / 7.5-jit-compile-diag (7745172): compileWasm の per-func compile loop に `std.debug.print` で `func[i] params=A results=B → ErrName` を stderr に出力。`> /tmp/<host>.log 2>&1` 経由で root-cause bisection が file から読める。
- §9.7 / 7.5-drop-unreachable (461cc1a): ARM64 emit に `drop` (vreg pop only; no machine bytes) + `unreachable` (`encB(0)` placeholder + bounds_fixups append) を追加; 末尾の trap-stub patcher が opcode bits 31..26 で B vs B.cond を判別して再 encode。jit-compile-runner 3→5 (block, const)。残 unreachable.0 / local_get.0 / local_set.0 / switch.0 / labels.0 / unwind.0 / nop.0 (7) は FP/i64 return + return op + mixed-type params が原因。
- §9.7 / 7.5-multi-arg-entry (e0af079): ARM64 emit.zig:134 の params reject を lift。AAPCS64 X1..X7 の最大 7 i32 params を prologue で `STR W{i+1}, [SP, #(i*8)]` 経由で local slot に snapshot。`local.get/.set/.tee` が `total_locals = num_params + num_locals` を bound にする。i64 / f32 / f64 / refs / 8 個目以降は今 deferred → UnsupportedOp。spec-jit-compile-runner 2/12 → 3/12 (forward.0.wasm clears)。x86_64 mirror は 7.8 開始時。
- §9.7 / 7.5-empty-module-fix (818e5a8): `compileWasm` が `function` section absent のとき空 CompiledWasm を返す + `linker.link` が 0-body case で empty JitModule を返す。inline test (8-byte header → 0 sigs / 0 results) 追加。jit-compile-runner: 1→2 passed (empty.wasm clears)。残り 10 fails はすべて multi-arg UnsupportedOp。
- §9.7 / 7.5-spec-jit-compile-runner (217c214): `test/spec/jit_compile_runner.zig` + `zig build test-spec-jit-compile` build step。`test/spec/{smoke,wasm-1.0}/` 12 fixtures を `engine.runner.compileWasm` でぶん回す。1/12 pass; 11/12 fail のうち 10/11 は arm64/emit.zig:134 の params-len reject、1/11 は empty.wasm の MissingTypeSection。test-all 未追加 (Mac aarch64 only)。
- §9.7 / 7.7-cc-pivot-shadow-space (0789c6e + 6e935c9): emit.zig 直接/間接 CALL 両方を `emitShadowAlloc` / `emitShadowFree` で wrap (Win64 32-byte; SysV no-op)。byte-offset 計算で imm value (32) と SUB encoding length (4) を取り違えていた initial bug は 6e935c9 で修正。LOOP/SKILL/CLAUDE.md に並列バックグラウンド + ファイル出力 + 再実行禁止のルールを伝搬 (cd81b8e)。
- §9.7 / 7.7-cc-pivot-emit (68675d4 + cfa5d04): `current_cc` + `current` alias を abi.zig に追加 (compile-time switch on `builtin.target.os.tag`); emit.zig が prologue / call-site で `abi.current.entry_arg0_gpr` + `abi.current.arg_gprs` を読む; win64.allocatable_gprs は slots 0..5 を SysV と同一順序にして cross-Cc test stability を確保; 3 abi tests + 1 emit test fix-up。
- §9.7 / 7.7-deferred-Win64 (219d461): Cc enum {sysv, win64} + per-Cc namespace (arg_gprs / callee_saved / shadow_space / entry_arg0); top-level aliases stay SysV; emit-side Cc-pivot は次の sub-chunk; 11 tests。
- §9.7 / 7.7-fp-end-fix (57cf94c): D-032 discharge — function-level end が `func.sig.results[0]` で分岐 (i32→.d / i64→.q / f32+f64→MOVAPS XMM0 / v128→UnsupportedOp); 4 byte-level tests。
- §9.7 / 7.7-fp-mem (3255c29): emitMemOp に is_fp 分岐 + encMovssMovsdMemBaseIdx; 6 tests。
- §9.7 / 7.7-fp-trunc-trap-{signed,unsigned} (eff1c75 / 78d5b06): Wasm 1.0 trapping f→i 8 ops。
- §9.7 / 7.7-fp-trunc-sat-{signed,u32,u64} (20a2c0e / 18314cf / 7983dd3): Wasm 2.0 saturating 8 ops。
- §9.7 / 7.7-fp-convert-{simple,unsigned} (2e60605 / df99e67): promote/demote/reinterpret + signed/unsigned i→f。
- §9.7 / 7.7-fp-{minmax,copysign,unary,compare,binary,const} 系: SSE2 全 surface (1205ae0 / 6af5239 / d51c1b8 / bc4348d / 895ac3e / f062800)。
- §9.7 / 7.7-call-{direct,indirect} + 7.7-wrap (d071173 / 2248e03 / 12cd04c)。
- §9.7 / 7.7-mem-{load,store} + globals + control 系 + i32 ALU 全 surface (c0711fb..59ed705)。
- §9.7 / 7.6 a/b/c (739de07 / 3c78b63 / 344d393)。
- §9.7 / 7.5d 完全クローズ (sub-b chunks 1-10) (48b9745)。
- ADR-0023 §7 18 items + ADR-0024 + ADR-0025 (Phase A) DONE。
