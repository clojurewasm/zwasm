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

直近 commit (HEAD = `3253a68`):

- `3253a68` §9.7 / 7.5-fp-params (V0..V7 STR S/D; encStrSImm + encStrDImm; 5/12 stays)
- `953eedf` §9.7 / 7.5-i64-params (i64 + STR X; 5/12; D-033 filed)
- `d286cbc` §9.7 / 7.5-nop (ARM64 nop; 5/12)
- `7745172` §9.7 / 7.5-jit-compile-diag (per-func stderr log)
- `461cc1a` §9.7 / 7.5-drop-unreachable (drop + unreachable; 3→5)
- `e0af079` §9.7 / 7.5-multi-arg-entry (X1..X7 i32 params; 2→3)

**Active task**: fp-params landed (5/12; local_get/set.0 が
SlotOverflow に shift — regalloc pool が 5-param + body で枯渇)。
**Diagnostic 後の残 fails**:
- local_get.0 / local_set.0 — SlotOverflow @ func[9] params=5 (regalloc
  pool 枯渇; spill enable で unblock)
- switch.0 func[0] — `return` op 未実装
- nop.0 / unwind.0 — UnsupportedOp (deeper op gap)
- labels.0 / unreachable.0 — OperandStackUnderflow (block-result +
  br + dead-code tracking バグ; 別の error class)

**NEXT** = `7.5-block-result-deadcode` (labels.0 / unreachable.0 の
OperandStackUnderflow バグを調査 + 修正。block (result T) 内で
br 0 後の dead-code を emit する際に `pushed_vregs.pop()` が
空 stack で発火する shape を特定して fix)。

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
| 7.5-block-result-deadcode | block (result T) + br + dead-code の operand-stack tracking バグ修正 | **NEXT** |
| 7.5-spill-enable | regalloc pool 枯渇時に spill を enable (5+ params + body で SlotOverflow 解消) | pending |
| 7.5-return-op | wasm `return` op (mid-function early exit; new return_fixups list patched at function-end) | pending |
| 7.5-local-type-aware | local.get/set/tee の width を declared type 別に (D-033 discharge) | pending |
| 7.5-spec-assertion-driver | wast2json で spec corpus を `.wasm` + assertion manifest 化 → JIT 経由で execute → pass/fail counts | pending |
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
