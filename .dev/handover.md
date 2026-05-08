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

## Current state — Phase 7 / §9.7 / 7.10 IN-PROGRESS

直近 commit (HEAD = `911b92c`):

- `911b92c` feat(p7): §9.7 / 7.10 chunk l (partial) — JIT entry() defensive guards
- `72c633d` chore(p7): mark §9.7 / 7.10 chunk k close
- `43e8336` feat(p7): §9.7 / 7.10 chunk k — x86_64 gpr.zig spill-region disp32 widening (D-048)
- `6b4bd2b` chore(p7): mark §9.7 / 7.10 chunk j close

**Phase status**: §9.7 / 7.5 + 7.8 + **7.9 [x]**。Phase 7 残 row = 7.10 /
7.11 🔒 / 7.12 / 7.13 🔒。

**§9.7 / 7.10 progress** (Linux x86_64 realworld_run_jit
**45/55 compile-pass** post-k, **0/55 run-pass** still):
- chunks a..k closed: D-029 ALU/FP、op_call 全 valtype、caller+
  callee stack-args、localDisp + RBP/RSP/spill disp32、br/br_if
  function-depth、op_memory u32 offset。D-048 (spill disp32)
  が大ジャンプ — compile-pass 0 → 45/55 (well past 40+ threshold)。
- post-k JIT compile remainder: 7 compile-op + 3 compile-val
  (= 10/55 still failing pre-runtime)。
- **run-stage SEGV blocker** (NEW): `ZWASM_JIT_RUN=1` で全 fixture
  segfault at 0x0 + recursive panic。compile 成功 → execution 失敗。
  原因候補: trap stub setup, host import wiring, WASI host,
  entry shim runtime data structure。debug 必要。

**§9.7 / 7.10 chain plan** (NEXT 群):
- **7.10-m (NEXT, AUTONOMOUS)**: D-049 自律調査・解消。chunk
  l Phase 1 で SEGV を JIT body 内部に narrow 済。具体的戦略
  (7 axes、優先度順):
  1. **lldb batch mode** (Mac 既に nix 経由でインストール済
     `lldb 21.1.8`): `lldb -b -o run -o "register read" -o
     "disasm -p -c 20" -o "memory read --size 1 --count 256
     \$pc" ./...zwasm-realworld-run-jit-runner` で SEGV まで
     auto-run + 状態 dump。OrbStack (Linux) には gdb/lldb 未
     インストール — 必要なら `apt install gdb` (chunk-m 内で
     行う、autonomous OK)。
  2. **Spike**: `private/spikes/jit_segv/` に最小 wasm
     (hand-crafted bytes, 1 関数 `(func) end` のみ、no imports)
     の in-process repro を作る → `compileWasm` +
     `runVoidExport` 直接呼んで JIT block bytes hex-dump。
  3. **SIGSEGV handler**: `std.posix.sigaction` で SEGV 捕捉
     → `faulting RIP/PC` print → `block.bytes.ptr` からの
     offset 計算 → emit-pass 逆引き。lldb 不要時の代替。
  4. **Bisection**: spike 最小 → `i32.const 0; drop; end` →
     `i32.add` → `local.get` → ... と instr 1 つずつ足して、
     どの op 追加で SEGV が始まるか二分探索。
  5. **JIT block protection 確認**: Linux `/proc/self/maps`
     read; macOS `vmmap` + `pthread_jit_write_protect_np`。
  6. **JitRuntime 整合性**: `@sizeOf` / `@offsetOf` print →
     `jit_abi.zig` 定数と byte-by-byte 一致確認。
  7. **WebFetch 裏取り**: zig 0.16 + Mac M1 MAP_JIT / W^X /
     `pthread_jit_write_protect_np` 既知 issue、wasmtime
     `winch/codegen/x64` prologue/epilogue invariants。
  Likely candidates: prologue stack alignment (chunks f-k で
  frame layout 変化)、spill region SUB RSP imm32 化 (chunk-k)
  後の guard page 抵触、trap stub address calc (chunks f-i 後)。
  spike outcome → ADR or lesson per `lessons_vs_adr.md`。
- 7.10-br_table-fdepth (deferred): return-trampoline pattern。
  D-049 が片付いて 7.10 close 後の Phase 8 早期 work でも OK。
- 7.10-regalloc-port (deferred to Phase 8): D-029。

**Pre-existing infra (out-of-scope)**: `.githooks/pre_commit`
(snake_case) が fire しないため fmt/file_size/lint gate 無効。
fmt drift 38 files, hard-cap 超過 3 files, lint warns 4 (全
pre-existing)。修復は専用 chore + 大規模 fmt + 分割 ADR 必要。

> **🔒 Phase 7 → 8 hard gate** が §9.7 / 7.13 に登録済。Detection
> は Resume Step 2 + Step 7 re-target。詳細 `phase8_transition_gate.md`。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`。

## Open structural debt (pointers)

- **D-049 (now)** run-stage SEGV — chunk-m autonomous strategy 上記。
- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後再評価。
- **D-026** env-stub host-func wiring (cross-module dispatch)。
- **D-029** parallel-move 経路完備、reject は regalloc port 後 discharge。
- 詳細・staleness check は `.dev/debt.md`。
- ADR-0025 (Zig host API) Phase B/D は post-7.8 — `0025_zig_library_surface.md`。

## Recently closed
- §9.7 / 7.10 chunks a..l-partial (`a8777ac`..`911b92c`)。
  compile-pass 0 → 45/55 (D-048 が大寄与)。run-stage SEGV = D-049。
- §9.7 / 7.9 [x] — arm64 realworld JIT 52/55 compile-pass。
