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

直近 commit (HEAD = `461cc1a`):

- `461cc1a` §9.7 / 7.5-drop-unreachable (drop + unreachable + B-fixup patcher; 3/12 → 5/12)
- `e0af079` §9.7 / 7.5-multi-arg-entry (ARM64 X1..X7 i32 params; 2→3)
- `818e5a8` §9.7 / 7.5-empty-module-fix (0-function modules accept; 1→2)
- `217c214` §9.7 / 7.5-spec-jit-compile-runner (corpus walker)
- `3e33ead` chore(p7): audit catch-up — flip §9.7 / 7.3 / 7.4 / 7.6 [x]
- `884d7d8` chore(p7): mark §9.7 / 7.7 [x]

**Active task**: drop + unreachable landed (5/12 pass)。残り 7
fails の原因 (調査済): unreachable.0 + local_get/set.0 = i64/f32/f64
return-type を ARM64 end-handler が未対応; switch.0 = `return` op 未実装;
labels.0 = OperandStackUnderflow (block-result + br interaction); nop.0 =
mixed-type params (i64+f32+f64 mixed); unwind.0 = stack-discard at br
with multi-type values。**NEXT** = `7.5-arm64-end-fp-i64` (ARM64
end-handler を `func.sig.results[0]` で分岐: i32→W0, i64→X0,
f32→S0, f64→D0; `7.7-fp-end-fix` の x86_64 mirror)。これで
unreachable.0 / local_get.0 / local_set.0 の 3 件 unblock 見込み。

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
| 7.5-arm64-end-fp-i64 | ARM64 end-handler を result kind で分岐 (i32→W0 / i64→X0 / f32→S0 / f64→D0) — 7.7-fp-end-fix mirror | **NEXT** |
| 7.5-return-op | wasm `return` op (mid-function early exit; jump to function epilogue + result marshal) | pending |
| 7.5-mixed-type-params | param signature が i64/f32/f64 を含む場合の prologue marshalling (X1..X7 を type-aware に) | pending |
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
