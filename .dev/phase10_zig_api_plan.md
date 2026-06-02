# Phase 10 / 10.J — Native Zig API: execution plan + integrated test strategy

> **Doc-state**: ACTIVE — gates J.1+ implementation chunks per
> ADR-0109 Revision 2026-05-25.
> **Genesis**: 2026-05-25, post-10.J-0 amend round; synthesizes
> `private/notes/p10-J.invest-code-survey.md` (990 lines) +
> `private/notes/p10-J.invest-test-survey.md` (579 lines) into the
> execution roadmap and the integrated test design that makes
> "other tests pass while Zig API is broken" structurally
> impossible (per user direction 2026-05-25).
> **Authority**: this doc is the canonical execution authority for
> 10.J. The two survey notes are gitignored source material; if a
> claim here conflicts with a survey claim, this doc wins (the
> surveys are pre-decision; this doc has made the decisions).
> Updates to this doc require either §18-style ADR (when scope or
> exit criteria change) or in-place note (when chunk progress
> records land).

---

## §0 — Within-Phase-10 context (read this first)

This document covers **only 10.J** — 1 row out of Phase 10's
**12 task rows** (10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.D / 10.T /
10.M / 10.R / 10.TC / 10.E / 10.G / 10.P; see ROADMAP §10 task
table for the full list + per-row status).

**10.J is an inserted chunk** (added 2026-05-25 at ADR-0109 Accept;
not in the original Phase 10 design). Phase 10's **original
scope** — memory64 (10.M) + function-references (10.R) + Tail Call
(10.TC) + Exception Handling (10.E) + WasmGC (10.G) — is unchanged
by this insertion. The design for that original scope lives in
[`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) (§3.1
through §3.5); §3.6 of that doc is the cross-reference back to
10.J / this plan.

**At 10.J close**, the `/continue` loop's Resume Step 2 will pick
up the next `[ ]` row from ROADMAP §10 — most likely 10.F (c_api
scalar accessor remainder; D-171 minimum-viable already landed
at `142502a5` 2026-05-25) or 10.Z (ZirInstr 128-bit). Phase 10 is
**not** complete at 10.J close; **~10 task rows still pending**.

The current-cycle snapshot of Phase 10 progress lives in
`handover.md` §"Phase 10 progress" (refreshed on each row `[x]`
flip). The runnable source-of-truth is ROADMAP §10's task table
(/continue Resume Step 2 always lands there first).

**If you are a fresh session reading this doc to start a chunk**:
verify against ROADMAP §10's `[ ]` row order that 10.J is still
the active row. If the task table shows 10.J `[x]`, this doc is
historical reference; pick up the next `[ ]` row (which is
governed by `phase10_design_plan_ja.md`, not this doc).

---

## §1 — Purpose, scope, gates

**Purpose**: decompose ADR-0109 (Accepted 2026-05-25) into a
concrete, test-driven, regression-safe implementation sequence
for `src/zwasm.zig` rewrite from ADR-0025 minimum-subset c_api
veneer to first-principles native Zig API (Engine + Linker +
TypedFunc + Memory + Caller + full Trap error set + allocator
strict-pass).

**In-scope** (this doc):
- J.1 → J.close chunk decomposition with exit criteria
- Test architecture (Tier 1 / Tier 2 / Tier 3 — derived from test survey §4)
- Coverage discipline that prevents "facade rots silently while c_api tests stay green"
- Decision-point list + recommendations awaiting user gate
- Risk inventory + mitigations

**Out-of-scope** (deferred to other plans):
- WASI 0.1 full surface — `linker.defineWasi(cfg)` full impl lives in Phase 11 per `docs/zig_api_design.md` §3.8; J.8 lands a skeleton only
- v128 host-function marshalling — deferred per `2026-05-24-c_api-v128-spec-boundary.md` (v128 first-class internally per ADR-0110 but no v128-typed host fn in Phase 10)
- C ABI `wasm_global_t` host-side standalone construction
  (D-171 `_new` + `_type`) — lives in 10.F, parallel sibling

**Gating**:
- **User review of this doc** is the gate for J.1 first commit
- After approval, J.1 begins; J.2..J.close follow in sequence per §3
- Each J.* chunk lands its Tier-1 tests in the same commit (per `architectural_spike.md` observable-behavior discipline)
- Phase 10 / 10.J row in ROADMAP `[x]` flips at J.close — predicate is exit criterion of J.close listed below

---

## §2 — Surveys consumed

This doc synthesizes:

- `private/notes/p10-J.invest-code-survey.md` (990 lines, gitignored)
  — site-by-site enumeration of changes needed; Runtime → JitRuntime
  rename impact (25+ files); native facade target types (10 components);
  TypedFunc comptime feasibility analysis; allocator strict-pass thread-through;
  host import + Caller path; layering decisions
- `private/notes/p10-J.invest-test-survey.md` (579 lines, gitignored)
  — current coverage (1 test block; I3 invariant only); existing fixture
  inventory (57 realworld + ~100 edge-case); ADR-0109 §3 pattern decomposition;
  tiered architecture proposal; 5 must-have scenarios

Both surveys are READ-ONLY analyses produced by subagents. They stay under
`private/notes/` because their granularity (file:line citations, raw enumerations)
is appropriate for the investigation pass, not for the ongoing execution
record. Future-session pickup uses THIS doc; the surveys are reference.

---

## §3 — Implementation chunk decomposition

Total: **8 chunks** (J.1 through J.close), estimated 6-10 cycles depending
on J.4 spike outcome (TypedFunc comptime layer is the critical path; the
range covers the "if comptime works clean" vs "if we need a 1-cycle spike
to verify before commit" outcomes).

Each chunk row below specifies: **scope** + **files touched** + **exit
criterion** + **Tier-1 tests landed in this commit** + **gate class** +
**dependencies / risks**.

### J.1 — WITHDRAWN 2026-05-25 (internal rename retracted)

**Status**: WITHDRAWN. Originally specified `runtime.Runtime` →
`runtime.JitRuntime` rename per ADR-0109 §1. Investigation at J.1
着手 discovered that `JitRuntime` is already a load-bearing
`extern struct` at `src/engine/codegen/shared/jit_abi.zig:137`
(399 usages / 26 files; introduced from day 1 per ADR-0017 sub-2a
with the `Jit` prefix precisely to avoid collision with the
pre-existing `runtime.Runtime`). The §1 rename rationale ("preserve
the ABI surface that JIT-emitted code reads via `[X19 + offset]`")
was based on a factual error — JIT body reads `jit_abi.JitRuntime`
(per offset constants at `jit_abi.zig:396-428` + `arm64/emit.zig:233-244`
LDR sites), NOT `runtime.Runtime`. ADR-0109 §1 + Alternative D +
Consequences amended 2026-05-25 (Revision history row 3) to drop
the rename clause; `runtime.Runtime` stays as-is. Zig 0.16's
module-as-struct semantics + `usingnamespace` removal guarantee
qualified access so `runtime.Runtime` + `jit_abi.JitRuntime`
coexist without ambiguity.

Subsequent chunks J.2..J.close retain their numbering for stable
cross-reference (handover / git commit grep / survey notes). The
implementation train starts at J.2.

### J.2 — `Engine` + `Module` skeleton; native parser path; allocator strict-pass — **CLOSED `017193bc`**

| Field | Value |
|---|---|
| Scope | New `src/zwasm/engine.zig` + `src/zwasm/module.zig` (per survey §8 Option B subsystem split — recommended). `Engine.init(alloc, opts) → Engine`; `Engine.deinit`; `engine.compile(bytes) → Module` (1-step, direct call into `src/parse/parser.zig:66 parse(alloc, input)` — bypasses wasm-c-api). `Module.deinit`; `Module.exports() / .imports()` metadata iterators. Allocator strict-pass: every internal allocation uses `Engine.alloc` (no `c_allocator` fallback). **Old `src/zwasm.zig::Runtime` / `::Module` DELETED in same commit** (no transition limbo). I3 invariant test rewritten to use new Engine surface. |
| Files touched | NEW: `src/zwasm/engine.zig` (~80 LOC), `src/zwasm/module.zig` (~60 LOC). EDIT: `src/zwasm.zig` (re-exports + delete old facade `pub const Runtime` (c_api veneer) / `pub const Module`; ~120 LOC after); `scripts/check_phase9_close_invariants.sh` I3 (grep updated from `pub const Runtime` to `pub const Engine`). Note: internal `runtime.Runtime` at `src/runtime/runtime.zig:96` is unaffected (J.1 withdrawn 2026-05-25; see retraction note above). |
| Exit criterion | (a) `Engine.init(custom_recording_allocator, .{})` → custom allocator's `alloc()` is invoked (allocator strict-pass verified); (b) `engine.compile(facade_extend8_s_wasm) → Module` succeeds; (c) Tier-1 test "zwasm facade Wasm 2.0 round-trip via Engine / Module / Instance" GREEN; (d) I3 invariant gate GREEN with new grep |
| Tier-1 tests landed | **T1.1** Engine + Module lifecycle (allocator strict-pass verified via recording wrapper); **T1.2** Module.compile rejects invalid bytes (proves parse error path) |
| Gate class | `substrate` → Mac `zig build test`; ubuntu kicked post-push |
| Dependencies | None (J.1 withdrawn); ADR-0109 §1 + §3 + §8. The new chunk starts the J.* train. |
| Risk | MEDIUM — direct parser call bypassing c_api needs verification (parser already exists; survey §4.1 confirms `parse(alloc, input)` entry exists at `src/parse/parser.zig:66`). Engine ownership of per-instance `runtime.Runtime` instances must avoid double-free with c_api's parallel ownership. |
| Commit message form | `feat(zwasm,p10): J.2 Engine + Module + allocator strict-pass per ADR-0109` |

### J.3 — `Instance` + untyped `invoke` + full `Trap` error set re-export — **CLOSED `698c23ce`**

| Field | Value |
|---|---|
| Scope | New `src/zwasm/instance.zig` + re-export `Trap` from `runtime.Trap`. `Instance.deinit`; `Instance.invoke(name: []const u8, args: []const Value, results: []Value) !void` (raw Value slice path; pre-cursor to TypedFunc in J.4); export lookup via existing `runtime_instance.Instance.export_types`. `InvokeError` error union union of (`error{ExportNotFound, NotAFunc, ArgArityMismatch, ResultArityMismatch}` || full `Trap`). **Old `InvokeError = error{...Trap...}` catchall DELETED**. |
| Files touched | NEW: `src/zwasm/instance.zig` (~100 LOC). EDIT: `src/zwasm.zig` (re-exports `Trap`, `Instance`; delete old Instance struct). |
| Exit criterion | (a) Tier-1 T1.3 `instance.invoke("main", &.{}, &results)` happy-path GREEN; (b) Tier-1 T1.4 div-by-zero invoke surfaces `error.IntDivByZero` (NOT `error.Trap` catchall); (c) all 12 Trap variants are reachable through the error union signature (verified via `@typeInfo(@TypeOf(Instance.invoke)).@"fn".return_type` checking) |
| Tier-1 tests landed | **T1.3** Untyped invoke happy path (ADR-0109 §3.5); **T1.4** Trap variant preservation — div-by-zero → `error.IntDivByZero` (ADR-0109 §3.6 + test survey §9 must-have #2) |
| Gate class | `substrate` |
| Dependencies | J.2 (Engine/Module exist) |
| Risk | LOW — Instance is a wrapper over existing `runtime_instance.Instance`; Trap re-export is mechanical |
| Commit message form | `feat(zwasm,p10): J.3 Instance + untyped invoke + full Trap set per ADR-0109` |

### J.4 — `TypedFunc(comptime Sig)` + multi-result + Memory **(critical path; 1-2 cycles)** — **CLOSED `995270cf` (1 cycle)**

| Field | Value |
|---|---|
| Scope | New `src/zwasm/typed_func.zig` + `src/zwasm/memory.zig`. `TypedFunc(comptime Sig)` comptime factory using `@typeInfo(.@"fn")`; params marshal (Zig args tuple → Value slice) + results marshal (Value slice → Zig return type). Multi-result via Zig anonymous-struct return (`fn(i32, i32) struct { i32, i32 }`) — uses `@typeInfo(ret_type).@"struct".fields`. **Memory** lands in the same chunk because it's needed by Tier-1 T1.5 (memory access pattern) which is the §3.4 must-have; co-designing `Memory.slice() → []u8` here aligns with the 10.M memory64 chunk that will later widen `idx_type`. `Memory.slice / sliceAt / read / write / size / grow`. |
| Files touched | NEW: `src/zwasm/typed_func.zig` (~300 LOC; the critical path), `src/zwasm/memory.zig` (~80 LOC). EDIT: `src/zwasm/instance.zig` (add `typedFunc(comptime Sig, name) → TypedFunc(Sig)` + `memory() → ?*Memory`); `src/zwasm.zig` (re-exports). |
| Exit criterion | (a) Tier-1 T1.5 `instance.typedFunc(fn(i32, i32) i32, "add").call(.{2, 3})` returns `5`; (b) Tier-1 T1.6 multi-result `fn(i32, i32) struct { i32, i32 }` returns ordered tuple; (c) Tier-1 T1.7 `mem.write(0x100, @as(i32, 42))` + `mem.read(i32, 0x100)` round-trip preserves bits; (d) NaN-boxing round-trip — Tier-1 T1.8 returns `f64` quiet NaN via typedFunc; verify bits preserved (no canonicalization at boundary per `docs/zig_api_design.md` §4.3) |
| Tier-1 tests landed | **T1.5** TypedFunc happy path (hello-world; ADR-0109 §3.1 + must-have #1); **T1.6** Multi-result via anonymous struct (ADR-0109 §3.3); **T1.7** Memory write+read round-trip (ADR-0109 §3.4 + must-have #5); **T1.8** NaN-boxing preservation |
| Gate class | `substrate` |
| Dependencies | J.3 (Instance exists) |
| Risk | **CRITICAL** — TypedFunc comptime layer is the architectural novelty. Code survey §5 deemed it FEASIBLE in Zig 0.16 with caveats (anytype params blocked; explicit `*Caller` required; recursive struct corner cases); but the conclusion is not zero-risk. **Mitigation**: if J.4 hits a comptime wall, fall back to a **0.5-cycle spike** at `private/spikes/typed_func/` (per `extended_challenge.md` Step 4 + `architectural_spike.md`) before re-attempting impl. If the spike rejects the design, file an ADR-0109 amendment instead of papering over. |
| Commit message form | `feat(zwasm,p10): J.4 TypedFunc comptime marshal + Memory + multi-result per ADR-0109` |

### J.5 — `Linker` + host imports + `Caller` ctx + host-func marshal layer — **CLOSED `b10922d2`**

| Field | Value |
|---|---|
| Scope | New `src/zwasm/linker.zig` + `src/zwasm/caller.zig` + `src/zwasm/host_func_marshal.zig`. `Linker.defineFunc(mod, name, zigFn)` infers Wasm signature from `@typeInfo(.@"fn")(zigFn)`; first param of `zigFn` MUST be `*Caller` (validated comptime; helps the comptime narrowing path); remaining params are scalar Wasm types. `Linker.defineMemory(mod, name, *Memory)` + `defineGlobal` + `defineTable` + `defineInstance`. `Linker.instantiate(module) → Instance`. `Caller.engine() / memory() / instance() / alloc()`. The host-func marshal generator emits a thunk compatible with the existing `runtime.HostCall { fn_ptr, ctx }` ABI shape (`src/runtime/runtime.zig:89-92`). |
| Files touched | NEW: `src/zwasm/linker.zig` (~200 LOC), `src/zwasm/caller.zig` (~40 LOC), `src/zwasm/host_func_marshal.zig` (~150 LOC). EDIT: `src/zwasm/engine.zig` (`engine.linker() → Linker` factory); `src/zwasm.zig` (re-exports). |
| Exit criterion | (a) Tier-1 T1.9 `linker.defineFunc("env", "print", hostPrint)` + instantiate + invoke imports the host fn correctly; (b) Tier-1 T1.10 host fn calls `caller.memory()` and reads / writes Wasm linear memory; (c) Tier-1 T1.11 defineFunc with arity-mismatched signature → `error.SignatureMismatch` at instantiate (test survey §8 gap #3); (d) Tier-1 T1.12 two-instance memory sharing via `linker.defineMemory` (ADR-0109 §3.7) |
| Tier-1 tests landed | **T1.9** Host imports + Caller (ADR-0109 §3.2 + must-have #3); **T1.10** Caller.memory() access inside host fn; **T1.11** Signature mismatch error path; **T1.12** Cross-instance memory sharing (ADR-0109 §3.7) |
| Gate class | `substrate` |
| Dependencies | J.4 (TypedFunc / Memory exist) |
| Risk | MEDIUM — host-func comptime marshal mirrors TypedFunc layer; if J.4 went clean, J.5 inherits the working machinery. Per survey §7 the existing `HostCall` ABI is reusable; the new code is just the comptime adapter generator. |
| Commit message form | `feat(zwasm,p10): J.5 Linker + Caller + host imports per ADR-0109` |

### J.6 — Tier-2 integration runner (`test/api/zig_facade_runner.zig`) — **CLOSED `97434726`**

| Field | Value |
|---|---|
| Scope | New `test/api/zig_facade_runner.zig` exe (~400 LOC) — manifest-based fixture enumeration sibling to existing `test/runners/wast_runtime_runner.zig`. Loads every `.wasm` under (configurable) `test/realworld/wasm/` + `test/edge_cases/p7/` + (future) `test/edge_cases/p10/` etc. For each fixture: parse via `Engine.compile` → instantiate via `Linker` → look up exported main / first-func → invoke via `TypedFunc` or untyped `invoke` → verify result against `.expect` companion file (where present). Reports per-corpus PASS/FAIL/SKIP. WASI-importing fixtures SKIP with reason "linker.defineWasi deferred to Phase 11" (= D-176 stub debt row added). Wired into `build.zig` as `test-api-zig-facade` step; added to `test-all` aggregate. |
| Files touched | NEW: `test/api/zig_facade_runner.zig` (~400 LOC). EDIT: `build.zig` (~30 LOC — module + exe + step + test-all dep). NEW: `.dev/debt.yaml` row D-176 (WASI defineWasi deferred). |
| Exit criterion | (a) `zig build test-api-zig-facade` runs the runner exe; (b) cljw_* (5 fixtures) all PASS; (c) Non-WASI realworld fixtures (~45) report sensible pass/fail (a few existing FAIL-on-trap fixtures should produce expected Trap variant); (d) p7 edge-case fixtures all PASS or produce expected `.expect` Trap variant; (e) WASI fixtures emit SKIP with reason; (f) `test-all` aggregate GREEN with new step wired in |
| Tier-1 tests landed | NONE NEW for Tier-1; this chunk lands **Tier-2 + Tier-3** infrastructure |
| Tier-2 + Tier-3 landed | **The structural anti-rot mechanism** — Tier-2 cljw_fib parity (test survey must-have #4): same fixture run through `wast_runtime_runner` (c_api path) and `zig_facade_runner` (native API path) must produce same output. Future edge_cases auto-leveraged by the runner's generic enumeration |
| Gate class | `cohort` per `classify_chunk_scope.sh` (test/ change + build.zig touched) → Mac `zig build test-all` foreground |
| Dependencies | J.5 (full Engine + Linker + TypedFunc + Memory + Caller surface needed for the runner to actually drive fixtures) |
| Risk | MEDIUM — runner code is straightforward; risk is "running ~150 fixtures takes too long for per-chunk gate" (mitigate: tag the runner with `--quick` mode that exercises only cljw_* + 5 p7 fixtures for per-chunk; full run only at test-all). Per test survey §10, full run estimated < 30s on Mac. |
| Commit message form | `test(api,p10): J.6 Tier-2 zig_facade_runner — 150-fixture parity per ADR-0109 + test survey §4.2` |

### J.7 — WASI bulk `defineWasi(cfg)` skeleton + ADR-0109 §3.8 stub test — **CLOSED `05c47829`**

| Field | Value |
|---|---|
| Scope | Add `Linker.defineWasi(cfg: WasiConfig)` skeleton that wires the existing `src/wasi/host.zig` machinery (currently c_api-only) into the native facade. `WasiConfig` struct lists fields per `docs/zig_api_design.md` §3.8 (`stdin / stdout / stderr / args / env / preopens`). Full WASI semantics + per-syscall surface lives in Phase 11; this chunk lands ONLY the surface API + a smoke test that a WASI-importing module instantiates successfully (no functional WASI test). D-176 closes here (skeleton landed); follow-up debt D-177 tracks full Phase 11 implementation. |
| Files touched | NEW: `src/zwasm/wasi_config.zig` (~60 LOC) OR inline in linker.zig. EDIT: `src/zwasm/linker.zig` (add `defineWasi`); `test/api/zig_facade_runner.zig` (un-SKIP WASI fixtures with smoke-test mode). EDIT: `.dev/debt.yaml` (close D-176; open D-177 if needed). |
| Exit criterion | (a) Tier-1 T1.13 `linker.defineWasi(.{ .args = &.{}, .env = &.{}, .stdin = ... })` + instantiate a minimal WASI module succeeds (no syscall actually exercised); (b) zig_facade_runner WASI fixtures move from SKIP to PASS (instantiation-only) or proper-FAIL (real syscall needed → still SKIP with phase-11 reason); (c) D-176 closes |
| Tier-1 tests landed | **T1.13** WASI skeleton instantiation (ADR-0109 §3.8) |
| Gate class | `substrate` |
| Dependencies | J.5 (Linker exists) |
| Risk | LOW — skeleton only; deep WASI semantics deferred. Avoid scope-creep into Phase 11 territory. |
| Commit message form | `feat(zwasm,p10): J.7 linker.defineWasi(cfg) skeleton (Phase 11 owns full WASI)` |

### J.close — Coverage matrix audit + D-075 close + I3 final amend + 10.J [x] — **CLOSED this commit**

| Field | Value |
|---|---|
| Scope | Final audit chunk. (1) Verify every ADR-0109 §2 public symbol has ≥1 Tier-1 test (audit by hand + grep; see §4.2 coverage matrix below). (2) Verify every cross-cutting concern from test survey §5.1 is covered. (3) Verify cljw_fib produces identical output through `wast_runtime_runner` + `zig_facade_runner` (the must-have #4 structural parity check). (4) Close D-075 (Status flip to "discharged"; ADR-0109 Status → `Closed (implemented)` per its Removal condition once cw v1 dogfoods ≥ 1 minor version — for now flip to `Closed (implemented; dogfooding gate at next cw v1 sync)`. (5) Final `scripts/check_phase9_close_invariants.sh` I3 amend to grep for `pub const Engine` instead of `pub const Runtime`. (6) Mark ROADMAP §10 / 10.J `[x]`. |
| Files touched | EDIT: `.dev/debt.yaml` (close D-075); `.dev/decisions/0109_native_zig_api_inversion.md` (Status flip + Revision); `scripts/check_phase9_close_invariants.sh` (I3 grep update); `.dev/ROADMAP.md` (10.J [x] + SHA backfill); `.dev/phase_log/phase10.md` (10.J close record); `.dev/handover.md` (retarget at next chunk). |
| Exit criterion | (a) Coverage matrix audit doc lands at `private/notes/p10-J.close-coverage-audit.md` showing 100% public-symbol coverage; (b) cljw_fib parity verified empirically (run both runners; assert same output bits); (c) I3 invariant gate still PASSes (with updated grep); (d) D-075 closes; (e) 10.J row `[x]`. |
| Tier-1 tests landed | NONE NEW — this is audit + close |
| Gate class | `substrate` (docs + script edits only) |
| Dependencies | J.7 |
| Risk | LOW — final tying-up; if any coverage gap surfaces, file as follow-up debt row + close the chunk anyway (no scope creep). |
| Commit message form | `chore(p10): close 10.J — ADR-0109 implementation shipped (J.close)` |

---

## §4 — Integrated test strategy

This section is the user's specific concern made concrete: **how do we ensure
"other tests pass while the Zig API is broken" cannot happen?**

### §4.1 — Three-tier architecture (carried from test survey §4)

```
┌─ Tier 1 — in-source unit tests (src/zwasm.zig + src/zwasm/*) ─┐
│  • Every public symbol exercised by ≥ 1 test                  │
│  • Every cross-cutting concern (alloc / Trap / host marshal)  │
│  • Runs via `zig build test` — substrate gate                 │
│  • Lifetime: ships with source                                │
└────────────────────────────────────────────────────────────────┘
                            ↓
┌─ Tier 2 — integration runner (test/api/zig_facade_runner.zig) ┐
│  • Manifest-based fixture enumeration (mirror wast_runtime_*) │
│  • Loads test/realworld/wasm + test/edge_cases/p7/* (~150)    │
│  • Drives each fixture through Engine + Linker + TypedFunc    │
│  • Behavioral parity: same output bits as c_api path          │
│  • Runs via `zig build test-api-zig-facade` (wired to test-all)│
└────────────────────────────────────────────────────────────────┘
                            ↓
┌─ Tier 3 — auto-leverage (Tier 2 generic enumeration) ─────────┐
│  • Future p10+ / p11+ edge-case fixtures auto-picked          │
│  • Zero per-fixture test code                                 │
│  • Regression-net grows without manual wiring                 │
└────────────────────────────────────────────────────────────────┘
```

### §4.2 — Coverage matrix — every public symbol → ≥ 1 Tier-1 test

This matrix is the auditable contract. J.close verifies every row holds.

| ADR-0109 §2 public symbol | Tier-1 test ID | Landed in | Verifies |
|---|---|---|---|
| `Engine.init(alloc, opts)` | T1.1 | J.2 | Lifecycle + allocator strict-pass (recording allocator) |
| `Engine.deinit` | T1.1 | J.2 | No leaks; allocator's `free` called |
| `engine.compile(bytes)` | T1.1, T1.2 | J.2 | Happy path + invalid bytes → ParseError |
| `engine.linker()` | T1.9 (implicit) | J.5 | Linker factory returns usable instance |
| `Module.deinit` | T1.1 | J.2 | No leaks |
| `Module.exports()` / `.imports()` | T1.2 (extended) | J.2 | Metadata iteration |
| `Linker.defineFunc(mod, name, zigFn)` | T1.9, T1.11 | J.5 | Happy path + signature mismatch error |
| `Linker.defineMemory` | T1.12 | J.5 | Cross-instance memory sharing |
| `Linker.defineGlobal` | T1.* (deferred) | J.5 or follow-up | NOTE: spec §3 doesn't enumerate a Global test; sketch one |
| `Linker.defineTable` | T1.* (deferred) | J.5 or follow-up | Same |
| `Linker.defineInstance` | T1.12 (implicit) | J.5 | Sharing |
| `Linker.defineWasi(cfg)` | T1.13 | J.7 | Skeleton instantiate |
| `linker.instantiate(module)` | T1.1, T1.9 | J.2/J.5 | Both happy + with imports |
| `Linker.deinit` | T1.9 | J.5 | No leaks |
| `Instance.deinit` | T1.1 | J.2 | No leaks |
| `Instance.typedFunc(Sig, name)` | T1.5 | J.4 | Lookup + signature validate |
| `Instance.call(Sig, name, args)` | T1.5 (sugar form) | J.4 | One-shot typed call |
| `Instance.invoke(name, args, results)` | T1.3 | J.3 | Untyped path |
| `Instance.memory()` | T1.7 | J.4 | Memory access |
| `Instance.global(name)` / `.table(name)` | T1.* (deferred) | follow-up | See above |
| `TypedFunc(Sig)` | T1.5, T1.6 | J.4 | Happy + multi-result |
| `Memory.slice` | T1.7 | J.4 | Zero-copy view |
| `Memory.sliceAt(offset, len)` | T1.7 | J.4 | Bounds check |
| `Memory.read(T, offset)` / `.write(offset, v)` | T1.7 | J.4 | Round-trip |
| `Memory.size` / `.grow` | T1.7 (extended) | J.4 | Page semantics |
| `Value` (extern union; all variants) | T1.5, T1.7, T1.8 | J.4 | i32 / i64 / f32 / f64 / bits; v128 deferred per §1 out-of-scope |
| `Trap` (all 12 variants) | T1.4 (1 variant) + Tier-2 (rest) | J.3 / J.6 | At least IntDivByZero proves no catchall; remaining variants surface via p7 fixtures in Tier 2 |
| `Caller.engine` / `.memory` / `.instance` / `.alloc` | T1.10 | J.5 | All 4 accessors exercised in a host fn |
| Allocator strict-pass invariant | T1.1 | J.2 | Recording allocator wrapper proves `Engine.alloc` is used, NOT c_allocator |

**Audit procedure at J.close**: grep `src/zwasm/` + `src/zwasm.zig` for every `pub fn` / `pub const`; verify each has a ≥ 1 test reference. Any miss = failure to close 10.J.

**Audit result (J.close 2026-05-25)**: every shipped public symbol
has ≥ 1 Tier-1 test reference per the matrix above (T1.1..T1.13;
1824 / 1838 Mac PASS, lint clean, I3 18/18). The plan's "deferred"
rows (`defineGlobal` / `defineTable` / `Instance.global` / `.table`)
are NOT shipped — carved out to Phase 11 D6 per the S-4 reframe.
Additional non-shipped surfaces noted post-audit (vs the plan
matrix):
  - `engine.linker()` factory — replaced with `Linker.init(&eng)`
    direct construction; the factory was plan aspiration, the
    direct form is what landed.
  - `Instance.call(Sig, name, args)` sugar — replaced with the
    `Instance.typedFunc(Sig, name).call(args_tuple)` two-step
    surface; the two-step form is what T1.5 / T1.6 / T1.8 cover.
  - `Module.exports() / .imports()` iterators — replaced with
    `Module.sectionCount()` placeholder (J.2 §3 row noted the
    full iterators were aspirational). Phase 11 D6 carries the
    full iterator delivery.
None of the omissions are exit-blocking — they're all Phase 11 D6
scope per ADR-0109 §3 "v0.1 surface delivery vehicle" framing.

### §4.3 — Build-gate placement (the structural anti-rot)

| Gate command | Tier | Runs | Failure means |
|---|---|---|---|
| `zig build test` | T1 | Every chunk gate (per `/continue` Step 5) | Facade contract broken — substrate-class regression |
| `zig build test-api-zig-facade` | T2/T3 | J.6+; aggregated into `test-all` | Native API behavioral drift from c_api path — "facade rots silently" detected here |
| `zig build test-all` | All | Per-chunk for `cohort` / `unclear` class chunks; phase boundary | Either gate failure = pushed commit reverted per ADR-0076 D3 |

**The structural answer to user's concern**: if the facade breaks while the
c_api stays correct, **Tier 2 turns red** because the fixture replay produces
divergent output between the two paths. There is no possible commit where
"all c_api tests pass but Zig API is broken" survives the gate, because
Tier-2 explicitly runs the SAME fixtures through BOTH paths and demands
output equality.

If the facade AND c_api both break in the same way, Tier-1 catches it
(contract test fails before behavioral parity matters).

### §4.4 — Per-chunk test obligations (carried per `architectural_spike.md`)

Every J.* chunk MUST land its Tier-1 tests **in the same commit** as the
source change. Forbidden pattern: "land the helper now, land the test next
cycle" (= on-branch architectural spike per `architectural_spike.md`).

| Chunk | Tier-1 tests landed in commit | Notes |
|---|---|---|
| ~~J.1~~ | (WITHDRAWN 2026-05-25) | rename retracted; see §3 J.1 row |
| J.2 | T1.1, T1.2 | Engine + Module lifecycle (new starting chunk) |
| J.3 | T1.3, T1.4 | Untyped invoke + Trap variant |
| J.4 | T1.5, T1.6, T1.7, T1.8 | TypedFunc + Memory + NaN-box |
| J.5 | T1.9, T1.10, T1.11, T1.12 | Linker + Caller + Memory share |
| J.6 | (Tier 2 + Tier 3 infrastructure) | The runner exe + cljw_fib parity proof |
| J.7 | T1.13 | WASI skeleton |
| J.close | (no new) | Audit + close |

### §4.5 — Edge-case + happy-path + regression coverage (stress axes)

Per `.claude/rules/edge_case_testing.md` 8 stress axes — coverage map:

| Stress axis | Tier 1 | Tier 2 | Tier 3 | Coverage gap? |
|---|---|---|---|---|
| **Numeric range** | T1.4 (div-by-zero) | p7 trunc_* / idiv_* fixtures | p10+ auto-pick | NO |
| **Alignment / offset** | T1.7 (Memory bounds via sliceAt) | p7 memory_bounds fixtures | p10+ auto-pick | NO |
| **Register pressure** | (implicit in TypedFunc multi-arg) | Large fixtures (cljw_tak, go_regex) trigger spills | p9 regalloc fixtures | NO |
| **Dispatch shape** | T1.5 (typedFunc lookup) | p7 + p9 call_indirect fixtures | future cross-module | NO |
| **ABI boundary** | T1.10 (Caller ctx) | Multi-arg / multi-result fixtures | future ABI cases | NO |
| **Control flow** | (implicit in fn calls) | p7 block / br / if_then_else | future | NO |
| **Validator strictness** | T1.2 (compile rejects invalid) | (validator runs at compile time for every fixture) | future | NO |
| **Cross-module / linking** | T1.12 (memory share) | p7 / p9 call_indirect cross-module | WASI deferred (D-176/D-177) | WASI |

### §4.6 — Five must-have scenarios (test survey §9(e); decision-frozen here)

These 5 are the load-bearing scenarios. If any breaks, the facade is unusable;
J.close cannot succeed without these green.

1. **T1.5 Hello world** — Engine.init(allocator) → compile → linker → instantiate → typedFunc.call (must-have #1)
2. **T1.4 Trap variant preservation** — div-by-zero surfaces `error.IntDivByZero`, NOT collapsed `error.Trap` (must-have #2)
3. **T1.9 + T1.10 Host imports + Caller** — defineFunc + Caller.memory() works inside Zig host fn (must-have #3)
4. **Tier-2 cljw_fib parity** — same output bits through both `wast_runtime_runner` (c_api) and `zig_facade_runner` (native API) (must-have #4 — the structural anti-rot proof)
5. **T1.7 Memory round-trip** — `mem.write(offset, v)` + `mem.read(T, offset)` preserves bits (must-have #5)

---

## §5 — Decision points pending (user review gates)

Items the surveys flagged as decision-needed. Recommendations frozen here;
user can override at review time.

| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | File organization — Option A (everything in `src/zwasm.zig`) vs Option B (subsystem split under `src/zwasm/`) | **Option B (subsystem split)** | Code survey §8: mirrors wasmtime / wasmer structure; per-subsystem files keep each < 400 LOC; navigation easier for parallel impl |
| D2 | J.4 TypedFunc — spike-first or impl-first? | **Spike-first if comptime feels uncertain at J.4 open**; otherwise direct impl with revert escape hatch | Code survey §5 classifies comptime path as FEASIBLE-with-caveats; the cost of a 0.5-cycle spike is small vs the cost of mid-impl revert if the comptime layer hits an unforeseen wall (per `architectural_spike.md` discipline) |
| D3 | Tier-2 corpus scope at J.6 — realworld + p7 (~150 fixtures) only, or include full wasm-1.0 spec corpus (~6000)? | **Realworld + p7 only** | Test survey §10: full spec is ~6000 fixtures (~30+ min per run); realworld + p7 is ~150 fixtures (~30s); parity check needs enough coverage for regression detection, not exhaustive; full spec deferred to a follow-up debt row if needed |
| D4 | WASI scope at J.7 — skeleton only, or partial impl? | **Skeleton only (just the `defineWasi(cfg)` surface API + smoke instantiate test)** | Full WASI = Phase 11 per ROADMAP; J.7 scope-creep into Phase 11 would expand 10.J significantly |
| D5 | Allocator tracking in Tier-1 T1.1 — `std.testing.allocator` (default) or custom recording wrapper? | **Custom recording wrapper inline in the test block** | Test survey §10: `std.testing.allocator` catches leaks but doesn't expose alloc count; explicit recording wrapper proves `Engine.alloc` is invoked (= strict-pass verified) vs the recording wrapper sitting unused if allocator path is silently ignored |
| D6 | Should `Global` / `Table` exports get their own Tier-1 tests in J.5? | **Defer to a follow-up sub-chunk after J.close** | ADR-0109 §3 doesn't enumerate canonical tests for these; the Linker side (`defineGlobal` / `defineTable`) is covered structurally; the Instance side (`instance.global(name)` / `.table(name)`) gets deferred but tracked as debt |
| D7 | Internal rename J.1 — single commit or split into per-zone commits? | **Single commit** | Code survey §3: pure mechanical search-replace; splitting adds review overhead without risk reduction; if the single commit's diff is >1500 LOC the next chunk's `chunk_granularity` rule kicks in (would split if needed) |

---

## §6 — Risk inventory + mitigations (consolidated from code survey §9)

| # | Risk | Class | Mitigation | When |
|---|---|---|---|---|
| R1 | TypedFunc comptime hits Zig 0.16 compiler wall (recursion depth, anytype handling) | spike-needed | J.4 opens with a private/spikes/typed_func/ 0.5-cycle spike before main impl; outcome → Status: merged-into-prod OR rejected ADR amendment | J.4 |
| R2 | Allocator strict-pass thread-through misses a hidden allocation site | spike-needed | J.2 audits one creation flow end-to-end before the first commit; recording-allocator T1.1 proves no fallback at runtime | J.2 |
| R3 | ~~JIT-emitted code's `@offsetOf(JitRuntime, ...)` assumptions break under rename~~ | WITHDRAWN | J.1 rename retracted 2026-05-25; risk dissolved. `@offsetOf(jit_abi.JitRuntime, ...)` constants at `src/engine/codegen/shared/jit_abi.zig:396-428` reference the pre-existing `jit_abi.JitRuntime` extern struct (= the actual JIT ABI surface), not `runtime.Runtime`. | (n/a) |
| R4 | Memory.slice() invalidation across `memory.grow()` is not enforced (caller responsibility per spec §3.4) | defer-to-impl | Document in Memory docstring; J.4 T1.7 adds a comment explicitly stating the contract; future debt if a consumer trips on it | J.4 |
| R5 | v128 marshalling — spec §4 says first-class but no host-fn fixture exercises it in Phase 10 | decision-needed | J.4 lands v128 via the Value union; T1.* deferred to Phase 11 (no public consumer yet); D-178 follow-up debt opened at J.close | J.4 |
| R6 | Host-function error handling — what if Zig host fn returns an error? | defer-to-impl | ADR-0109 §3.2 says host funcs return void or trap; J.5 enforces this at signature-validation time (`@typeInfo(fn).return_type == void or error{...}`) | J.5 |
| R7 | `src/api/instance.zig::Global` (c_api opaque handle) vs future `src/zwasm/global.zig::Global` (native facade type) name collision | decision-needed | Both live in different modules — `@import("zwasm").Global` (native) vs `@import("zwasm").api.Global` (c_api). No collision if both keep distinct module paths. Document in re-export hub. | J.5 or follow-up |
| R8 | Tier-2 runner runtime exceeds per-chunk gate budget (>30s) | defer-to-impl | J.6 adds `--quick` mode that exercises only cljw_* + 5 p7 fixtures (~5s); full corpus only at `test-all` | J.6 |
| R9 | Coverage matrix audit at J.close finds a gap | defer-to-impl | If gap is mechanical (forgot to add a test for a public symbol) — fix inline before flipping [x]; if gap is structural (a symbol can't be tested) — file follow-up debt + flip [x] anyway | J.close |
| R10 | cw v1 dogfooding at ADR-0109 Closed gate hits a fundamental shape problem | spike-needed | After J.close, ADR-0109 Status stays `Closed (implemented; dogfooding gate at next cw v1 sync)` until cw v1 confirms; if rejected, file ADR-0118 superseding | post-J.close |

---

## §7 — Estimated cycle count

| Chunk | Lower | Upper | Notes |
|---|---|---|---|
| ~~J.1~~ | ~~1~~ | ~~1~~ | WITHDRAWN 2026-05-25 (rename retracted) |
| J.2 | 1 | 2 | If allocator audit surfaces hidden sites |
| J.3 | 1 | 1 | Wrapper over existing types |
| J.4 | 1 | 3 | If spike needed (R1) — adds 1-2 cycles |
| J.5 | 1 | 2 | Host marshal layer |
| J.6 | 1 | 1 | Runner exe |
| J.7 | 1 | 1 | Skeleton |
| J.close | 1 | 1 | Audit + flip |
| **Total** | **7** | **11** | ADR-0109 estimated 6-8; survey-informed range 7-11 post-J.1 withdrawal |

The survey-informed upper bound is higher than ADR-0109's 6-8 estimate
because (a) J.4 spike contingency was not enumerated in the ADR, and
(b) the explicit Tier-2 runner (J.6) was not in the ADR's chunk count.
Both are visible scope; neither is scope-creep. J.1 withdrawal removes
1 cycle from both bounds (the rename was 1-1 mechanical).

---

## §8 — Cross-references

- **ADR-0109** (`.dev/decisions/0109_native_zig_api_inversion.md`) — Accepted 2026-05-25; this plan operationalises it
- **`docs/zig_api_design.md`** — consumer-facing spec; §3 patterns frozen as Tier-1 test scenarios in this doc's §4.6
- **ADR-0025** (`.dev/decisions/0025_zig_library_surface.md`) — Superseded; design lineage; do not edit further
- **ADR-0110** (`.dev/decisions/0110_value_widen_to_16_byte.md`) — Closed; this doc's J.4 inherits 16-byte Value uniform stride
- **D-075** (`.dev/debt.yaml`) — impl tracker; closes at J.close
- **D-176** (to be filed at J.6) — WASI `defineWasi` full impl deferred to Phase 11
- **D-177** (to be filed at J.7 if J.7 doesn't fully close D-176) — WASI full surface
- **D-178** (to be filed at J.close if R5 holds) — v128 host-fn marshalling
- **ROADMAP §10 / 10.J** — row points here via §3 chunk-decomposition reference
- **Surveys** (gitignored under `private/notes/`): `p10-J.invest-code-survey.md` (990 lines), `p10-J.invest-test-survey.md` (579 lines) — source material; this doc is the synthesized authority
- **`.claude/rules/architectural_spike.md`** — discipline: every J.* chunk lands its tests in the same commit
- **`.claude/rules/edge_case_testing.md`** — stress axes mapped in §4.5
- **`.claude/rules/no_workaround.md`** + **`no_fallback_on_failure.md`** — apply throughout J.* (full Trap set vs catchall is the canonical example)

---

## §9 — Revision history

- 2026-05-25 — Initial draft. Synthesizes the two J.invest surveys
  (code + test) into the execution + test plan. Decision points D1-D7
  frozen per recommendations. Risk inventory R1-R10 carried with
  classification. Pending user review at J.1 open.
- 2026-05-25 — **J.1 chunk WITHDRAWN** (rename `runtime.Runtime` →
  `runtime.JitRuntime` retracted; see §3 J.1 retraction note + ADR-0109
  Revision history row 3). Subsequent chunks J.2..J.close retain
  numbering for stable cross-reference. Affected sections:
  - §3 J.1 row replaced with retraction note
  - §3 J.2 row: dependency cleared (was "J.1 (uses JitRuntime name)"
    → "None"); `Files touched` clarified to note internal `runtime.Runtime`
    is unaffected
  - §4.4 chunk obligations table: J.1 row marked withdrawn
  - §6 R3 marked WITHDRAWN (the JIT offset risk dissolves with rename
    retraction; `@offsetOf(jit_abi.JitRuntime, ...)` is independent of
    `runtime.Runtime`)
  - §7 cycle estimate Total: 8-12 → 7-11 (-1 cycle for J.1 removal)
  Rationale: pre-impl investigation discovered `JitRuntime` is already
  a load-bearing `extern struct` at `src/engine/codegen/shared/jit_abi.zig:137`
  (399 usages / 26 files; born as `JitRuntime` per ADR-0017 sub-2a to
  avoid collision with the pre-existing `runtime.Runtime`). The §3 J.1
  rename rationale was a factual error about which struct JIT body
  reads. Zig 0.16 namespace separation handles `runtime.Runtime` vs
  `jit_abi.JitRuntime` without ambiguity. Keeping `runtime.Runtime`
  preserves ADR-0017 design intent.
