# 0106 — Multi-result return convention reconsideration (replace per-shape Win64 thunks)

- **Status**: Closed (implemented; path (a) buffer-write) 2026-05-24
- **Date**: 2026-05-22
- **Author**: Shota Kudo + 2026-05-22 Agent 4 (v1/wasmtime comparative survey)
- **Tags**: phase-9, codegen, jit, abi, multi-value, win64, sysv, aapcs64
- **Companion**: ADR-0104 (Phase 9 honest-accounting reframe) — META decision; this ADR is the technical design for D-164 + D-094.

## Context

D-164 (`SKIP-WIN64-MULTI-RESULT`) covers 3171 `assert_return`
directives in `wasm-2.0-assert/` whose function bodies use Wasm
2.0 multi-value semantics. Root cause:

- v2 entry helpers in `src/engine/codegen/shared/entry.zig:765-833`
  use per-shape `extern struct FuncRet_i32i64` / `FuncRet_i32i32` /
  `FuncRet_i32f64` / `FuncRet_f64i32` / `FuncRet_f64f32` with
  `callconv(.c)` return.
- Win64 ABI §3.2.4: structs > 8 bytes returned via hidden RCX
  pointer (caller passes a result-buffer ptr in RCX, callee
  writes via the pointer + returns the pointer in RAX).
- JIT epilogue writes results to RAX/RDX directly (SysV / AAPCS64
  register-pair convention) — Zig's `callconv(.c)` Win64 reader
  expects hidden-RCX-pointer indirection → mismatch → garbage
  reads.

D-094 (filed 2026-05-14) is the SysV sibling: x86_64 SysV §3.2.3
caps result regs at RAX/RDX + XMM0/XMM1 (2 per class). Functions
returning > 2 same-class results need the MEMORY-class hidden-
indirect-result-buffer (RDI hidden first arg) — not implemented;
overflow results silent-truncated.

The current D-164 plan (in debt.md before ADR-0104 reframe) was
"per-shape Win64 inline-asm thunks" — duplicate `callI32i64NoArgs` /
`callI32i32NoArgs` / `callI32f64NoArgs` / `callF64i32NoArgs` /
`callF64f32NoArgs` Win64 paths via inline asm to bypass
`callconv(.c)` and read RAX/RDX directly. Precedent:
`callI32f64NoArgs` Win64 path at entry.zig:1156 (single inline-asm
thunk for one shape).

2026-05-22 Agent 4 comparative survey rejected this plan:

1. **v1 uses buffer-write entry ABI** (`~/Documents/MyProducts/
   zwasm/src/vm.zig:33`, `src/x86.zig:25`):
   ```
   fn ([*]u64 regs, *anyopaque, *anyopaque) callconv(.c) u64
   ```
   The `[*]u64 regs` is a caller-supplied buffer; JIT epilogue
   writes `regs[i]` for each result. The single `u64` return value
   is just trap status. **Sidesteps Win64 hidden-pointer ABI
   entirely** — `[*]u64` is a single arg, returned `u64` fits in
   RAX.

2. **wasmtime/cranelift uses uniform implicit-SRet ABI lowering**
   (`~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/x64/abi.rs:
   118-135, 345-351`):
   - When result aggregate exceeds register-pair capacity (SysV
     2-per-class or Win64 1 reg), the ABI lowering prepends an
     **implicit first arg** = pointer to caller-allocated result
     buffer.
   - JIT prologue captures the pointer; epilogue writes `[ptr +
     offset_i]` for each result.
   - The **same lowering** runs for SysV (RDI hidden arg) and
     Win64 Fastcall (RCX hidden arg) — uniform via cranelift's
     ABI lowering layer.
   - From `wasm-c-api/example/multi.c:12-23`: industry-consensus
     c_api uses `wasm_val_vec_t* results` parameter — a buffer-
     write convention. Reference programs assume callee writes
     via the buffer, not via struct return.

3. **No production Wasm runtime uses per-shape inline-asm
   thunks**. Per-shape thunks scale linearly with new return
   shapes — each Wasm 3.0 proposal (GC reftypes, EH tag pack,
   memory64 ptr64 results) adds new shapes, each needs a new
   thunk. Industry consensus rejects this design.

User Tier-0 decision (2026-05-22, recorded in ADR-0104 D3):

> JIT prologue stack-probe + buffer-write ABI 決心 — v1/wasmtime
> 証拠ベースで D-162/D-164 の設計 ADR を起案して honest に実装。

## Decision

Adopt **one of two paths** (final pick at §9.13 hard gate review;
user collaborative decision). Both paths reject per-shape Win64
inline-asm thunks.

### Path (a) — buffer-write entry ABI (v1-style)

Change entry-helper signatures in `src/engine/codegen/shared/
entry.zig` to:

```zig
fn(*JitRuntime, [*]u64 results, [*]const u64 args) callconv(.c) ErrCode
```

where `results` is caller-supplied (large enough for the function's
result types — known at instantiate time via the function-type
table), `args` is caller-prepared, and `ErrCode` is a trap status
(0 = OK, non-0 = trap kind).

JIT prologue extracts `results` pointer from arg1, stores per-
result to `results[i]` in the epilogue. The Win64 `callconv(.c)`
issue dissolves because the result is a single `ErrCode` scalar in
RAX.

**Pros**: simpler ABI surface (1 entry-helper shape for all
arities + result types), matches v1, matches wasm-c-api consensus.
**Cons**: caller must size `results` buffer correctly (compile-time
known from function type); slight indirection cost for return path
(buffer write vs register write).

### Path (b) — uniform implicit-SRet ABI lowering

Introduce an ABI-lowering layer in `src/engine/codegen/shared/abi.zig`
(or similar) that, when a function's result types exceed register-
pair capacity (per-arch + per-platform rule), prepends an implicit
first-arg pointer in the calling convention. JIT prologue captures
the implicit pointer; epilogue writes via the pointer.

The lowering is uniform across:
- SysV x86_64 (RDI hidden first arg)
- Win64 Fastcall (RCX hidden first arg)
- AAPCS64 (X8 hidden indirect-result pointer)

**Pros**: matches wasmtime/cranelift, preserves register-pair
fast-path for ≤ 2-result functions (no buffer indirection in the
common case), industry-standard.
**Cons**: implementation complexity higher (ABI lowering layer
needs careful sizing rules, per-platform divergence in the prologue
even though the lowering is "uniform" at the API level).

### Path (c) — per-shape Win64 inline-asm thunks (CURRENT D-164 PLAN)

**REJECTED** per ADR-0104 D3 reframe and Agent 4 §E2 analysis:

- Scales linearly with new return shapes (each Wasm 3.0 proposal
  adds new shape categories — GC reftypes, EH tag-pack, memory64).
- Industry consensus rejects it (neither v1, wasmtime, wasmer,
  wabt-interp, nor wasm-c-api reference uses per-shape thunks).
- Band-aid that doesn't fix the underlying ABI mismatch.
- The cap=2 mid-cycle experiment at `64d84219` (during W4 retry
  chain) tried to make the existing per-shape design "work on
  Win64" and produced exit-3 Writer-error crashes — the per-shape
  ABI is genuinely incompatible with Win64.

## Final pick (resolved 2026-05-23)

**Path (a) — buffer-write entry ABI** is selected per user collab
re-audit against ROADMAP §2:

- **P3 (cold-start over peak throughput)**: (a)'s 1 entry-helper
  shape costs ~1 extra memory write per result on the ≤ 2-result
  common case; (b)'s register-pair fast-path preservation buys
  peak throughput at the cost of an ABI-lowering layer. v2 chooses
  cold-start.
- **P10 (knowledge compression / teaching)**: (a) is "callee
  writes to caller-provided buffer" — one sentence. (b) requires
  explaining implicit-result-area pointer + per-platform sizing
  rules (SysV / Win64 / AAPCS64) + register-pair vs buffer
  threshold logic.
- **P13 (type up-front, invariants at design time)**: (a) is a
  single ABI invariant across all arities and platforms; (b)
  introduces per-arch sizing-rule invariants in the lowering
  layer.
- **§14 (API widening avoidance)**: (a) **reduces** the API
  surface from 5 `FuncRet_*` extern structs to 1; (b) preserves
  the per-shape catalog at the JIT layer (lowering-only change at
  the ABI boundary).
- **User Tier-0 decision (ADR-0104 D3)**: explicitly named
  "buffer-write ABI 決心" as the chosen direction.
- **Implementation cost**: 4 cycles ((a)) vs 6 cycles ((b)).

(b) remains documented above as a viable industry-standard
alternative, but is rejected for v2 on the principle alignment
above. The 4-cycle Implementation plan in §"If path (a) —
buffer-write entry ABI" is the autonomous-loop work scope.

The chosen design replaces the per-shape `FuncRet_*` extern
struct family.

## Implementation plan (post-Accept)

(Tracked by D-164 + D-094 in `.dev/debt.md`.)

### If path (a) — buffer-write entry ABI

1. **Cycle 1**: introduce `[*]u64 results` parameter in
   `entry.zig` entry-helper signature; update `runner.zig` /
   `instantiate.zig` callsites to allocate `results` buffer per
   function-type result-count.
2. **Cycle 2**: x86_64 JIT epilogue rewrites — write `results[i]`
   instead of RAX/RDX direct.
3. **Cycle 3**: arm64 JIT epilogue rewrites — write `results[i]`
   instead of X0/X1.
4. **Cycle 4**: remove `FuncRet_i32i64` / `FuncRet_i32i32` /
   `FuncRet_i32f64` / `FuncRet_f64i32` / `FuncRet_f64f32` extern
   structs from entry.zig. Remove `SKIP-WIN64-MULTI-RESULT` arm
   from `spec_assert_runner_base.zig`. Verify 3-host PASS for
   all `assert_return type-all-*` fixtures.

D-094 (SysV multi-result indirect-buffer) closes simultaneously
— the buffer-write ABI absorbs `> 2 same-class results` cases
without needing the SysV §3.2.3 hidden-RDI path.

### If path (b) — uniform implicit-SRet ABI lowering

1. **Cycle 1-2**: introduce ABI-lowering layer (per-arch + per-
   platform sizing rules; preserve register-pair fast-path for
   small results).
2. **Cycle 3**: SysV x86_64 implicit-RDI lowering.
3. **Cycle 4**: Win64 Fastcall implicit-RCX lowering.
4. **Cycle 5**: AAPCS64 implicit-X8 lowering.
5. **Cycle 6**: remove per-shape `FuncRet_*` extern structs.
   Remove SKIP arm. Verify 3-host PASS.

D-094 closes alongside (SysV uniform implicit-RDI is part of the
lowering).

## Alternatives considered

(Path (c) already covered above as REJECTED.)

### Alternative D — `wasm_val_vec_t* results` c_api-level signature

- **Sketch**: Make the entry helper signature literally
  `(rt, *wasm_val_vec_t results, *const wasm_val_vec_t args)`
  matching wasm-c-api reference programs' shape.
- **Why rejected**: too tightly coupled to the c_api surface; the
  internal JIT entry helper shouldn't depend on wasm-c-api type
  layout. Path (a)'s `[*]u64 results` is the right level of
  abstraction (single-arch-width per result; c_api wrappers
  marshal `wasm_val_t` ↔ `u64` outside the entry helper).

### Alternative E — Keep per-shape thunks BUT only on Win64

- **Sketch**: SysV + AAPCS64 keep `FuncRet_*` extern struct path;
  Win64 adds per-shape inline-asm thunks for ≤ 2-result cases,
  plus a generic buffer-write path for > 2 results.
- **Why rejected**: doubles the maintenance burden (two ABI shapes
  to maintain); doesn't solve the D-094 SysV >2-result issue.

## Consequences

### Positive

- **Eliminates D-164 SKIP-WIN64-MULTI-RESULT** (3171 directives).
  All `assert_return type-all-*` PASS on Windows post-implementation.
- **Eliminates D-094 SysV >2-result silent-truncate**.
  `break-multi-value`-shape functions return correct results on
  all hosts.
- **Industry-standard convergence** — both paths match v1 OR
  wasmtime; no per-shape thunk catalog to maintain.
- **Wasm 3.0 readiness** — multi-value extensions (GC reftypes,
  EH tag-pack, memory64 ptr64) don't require new shape catalogs;
  the uniform ABI absorbs them.

### Negative

- **Implementation cost**: 4 cycles (path a) or 6 cycles (path b)
  of `/continue` autonomous loop.
- **Performance**: minor — buffer-write path costs ~1 extra
  memory write per result vs register-direct on small cases.
  Acceptable given the simplicity gain. wasmtime's implicit-SRet
  approach (path b) preserves register-pair fast-path for ≤ 2
  results; path (a) doesn't (uniform buffer-write).

### Neutral

- **`callI32f64NoArgs` Win64 path at `entry.zig:1156`** — the
  existing single inline-asm thunk (precedent that motivated the
  per-shape proliferation) gets removed under either path.
- **c_api / Zig API result marshalling** is unaffected at the
  consumer-API level — they continue to use `wasm_val_vec_t*`
  / `[]Value` shapes. The change is internal-to-JIT.

## Removal condition

This ADR is permanent (chosen ABI is the project's multi-result
convention). Status: `Closed (Phase 9 DONE)` when D-164 + D-094
both close + all 3 hosts PASS `assert_return type-all-*` fixtures.

## References

- ADR-0104 (Phase 9 honest-accounting reframe — META; this ADR
  is one technical leg).
- ADR-0078 (`SKIP-WIN64-MULTI-RESULT` taxonomy row — removed
  after this ADR's implementation).
- D-094 (SysV multi-result MEMORY-class; closes alongside).
- D-164 (Win64 multi-result hidden-pointer; closes alongside).
- `private/spikes/adr-0106-cycle2/SPIKE.md` — cycle 2 migration
  design spike (Alt 2 per-module compile flag chosen);
  authored 2026-05-23 during cycles 1-3d foundation work.
- `private/spikes/adr-0106-cycle3e-call-lowering/SPIKE.md` —
  cycle 3e intra-module call lowering design spike; authored
  2026-05-23 after cycle 3d documented the 3-surface scope.
- v1: `~/Documents/MyProducts/zwasm/src/vm.zig:33` (entry
  signature with `[*]u64 regs`), `src/x86.zig:25` (SysV ABI
  shape), `src/cli.zig:2157` (epilogue Trap conversion).
- wasmtime: `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/
  x64/abi.rs:118-135, 345-351, 612, 628-648` (implicit-SRet
  lowering), `cranelift/codegen/src/isa/x64/abi.rs:101` (Cc-
  pivot), `cranelift/codegen/src/isa/x64/abi.rs:218-224` (per-
  call result-area pointer).
- wasm-c-api: `~/Documents/OSS/wasm-c-api/include/wasm.h:430-445`
  (`wasm_val_vec_t* results` declaration),
  `~/Documents/OSS/wasm-c-api/example/multi.c:12-23` (industry
  reference of buffer-write convention).
- Failed cap=2 experiment: commit `64d84219`
  (reverted at `b891b109`) — proves the per-shape ABI is
  genuinely incompatible with Win64; band-aid attempts produce
  Writer-error / RDX-clobber crashes.

## Revision history

| Date       | Commit       | Change                          |
|------------|--------------|---------------------------------|
| 2026-05-22 | `6bfd0c8c` | Initial draft (Proposed status; user picks path (a) or (b) at §9.13 hard gate review per ADR-0104 D5) |
| 2026-05-23 | `783517cb` | **Status: Proposed → Accepted with path (a) buffer-write selected** per user collab re-audit. ROADMAP §2 P3 + P10 + P13 + §14 (API widening avoidance) all favour (a) over (b); ADR-0104 D3 user Tier-0 decision explicitly named "buffer-write ABI 決心". (b) remains documented as a viable alternative but rejected for v2 on principle alignment. Implementation cost 4 cycles per §"If path (a)"; D-094 + D-164 close alongside. |
| 2026-05-24 | `4339eb02` | **Status: Accepted → Closed (implemented)**. D-094 + D-164 closed via cycles 2c+3e implementation; D-167 wire-up landed (`4339eb02` source + `fe666b0f` close). SKIP-WIN64-MULTI-RESULT arm removed from spec_assert_runner_base.zig; windowsmini test-all GREEN at `7680cbd2` (simd_assert 13351 / 0 fail / 0 directive fail). check_phase9_close_invariants.sh invariant I1c passes. Per Phase C ADR canonical pass (§9.12-I). |
| 2026-05-23 | cycles 1–3d | **Implementation cycles 1–3d landed** (`8f32eab29` … `d8f04182d`). API foundation (`entry_buffer_write.zig`, `BufferWriteFn`, `invokeBufferWrite`), ResultAbi enum threaded via `Allocation.result_abi` + `compileOne` param, x86_64 + arm64 emit branch prologue/epilogue/param-marshal on the flag, multi-result precedence fix (buffer_write > MEMORY-class), typed `invokeMultiResultNoArgs` helper. Verified end-to-end on Mac aarch64 + Linux x86_64 SysV for ALL 3 SKIP-arm shapes: `(i32,i32,i32)`, `(i32,i64)`, `(i64,i32)`. Remaining: cycle 3e/4 = substantial spec runner integration (per-module ABI selection + all ~84 entry-helper callsites OR parallel compile-twice; requires careful design + windowsmini phase-boundary verification). |
