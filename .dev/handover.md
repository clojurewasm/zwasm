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

## Current state — Phase 7 / §9.7 / 7.7 IN-PROGRESS

直近 commit (HEAD = `cd81b8e`):

- `cd81b8e` docs(workflow): propagate parallel-bg + file-logged gate rule (LOOP/SKILL/CLAUDE)
- `6e935c9` fix(p7) §9.7 / 7.7-cc-pivot-shadow-space — SUB/ADD encoding-length offset 修正 + LOOP.md 改訂
- `0789c6e` §9.7 / 7.7-cc-pivot-shadow-space (Win64 32-byte shadow at CALL; emitShadowAlloc/Free helpers)
- `e8a1051` chore(p7): retarget at 7.7-cc-pivot-shadow-space
- `cfa5d04` fix-up: 1-arg call test を Cc-aware 化
- `68675d4` §9.7 / 7.7-cc-pivot-emit (current_cc / current alias; entry_arg0 + arg_gprs per-Cc)
- `219d461` §9.7 / 7.7-deferred-Win64 (Cc enum + sysv/win64 namespaces)

**Active task**: cc-pivot-shadow-space 完了 (Win64 SUB/ADD RSP, 32
around CALL; 3-host green @ `cd81b8e`)。**NEXT** = 7.7 row を
`[x]` flip + 7.8 開始 (spec test pass=fail=skip=0 via x86_64 JIT
on Linux + Windows hosts). 7.8 は run-spec の JIT path wiring +
試験用 spec fixtures を JIT で実行する大きな chunk。
その後 7.9/7.10 realworld → 7.11 🔒 three-way differential →
7.12 audit → **🔒 7.13 hard gate** → 7.14 open §9.8。

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

完了済 31 chunk: skel / alu / cmp / eqz / shift / bitcount / locals /
control-{skel,if,table} / mem-{load,store} / globals / wrap /
call-{direct,indirect} / fp-{const,binary,compare,unary,copysign,
minmax,convert-{simple,unsigned},trunc-sat-{signed,u32,u64},
trunc-trap-{signed,unsigned},mem,end-fix} / deferred-Win64 /
cc-pivot-{emit,shadow-space}。
SHA は `git log --grep='§9.7 / 7.7-'` で取得可能。

7.7 sub-chunk table は空 (全 sub-chunk 完了)。次は §9.7 / 7.7
row 自体を `[x]` flip → 7.8 開始。

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
