# 0179 — Execution interruption + resource limits (fuel / epoch / store-limits)

- **Status**: Accepted
- **Date**: 2026-06-08
- **Author**: Claude (user-directed Tier-1 release-prep campaign)
- **Tags**: runtime, sandboxing, resource-limits, api, c-api, wasmtime-aligned

## Context

v2 is a "clean completion form" runtime but, as a **WebAssembly runtime**,
sandboxing and resource control are semi-mandatory (user directive 2026-06-08).
v1 had **fuel**, **timeout/deadline**, **cooperative cancellation**, and
**max-memory** — several community-contributed (timeout = DeanoC #6, cancellation
= jtakakura #28) — wired monolithically into `Vm` (`src/vm.zig`) + the custom C
API + CLI. The v2 redesign dropped all of them (verified absent: 0 grep matches
for `fuel`/`deadline` in `src/`; `src/include/zwasm.h` is an empty placeholder
reserving exactly these). `docs/migration_v1_to_v2.md` §1 lists them as the
headline v1-has/v2-lacks gaps. This is Tier-1 of the pre-release parity campaign.

**Reference runtime: wasmtime** (user-chosen exemplar). wasmtime deliberately
**factors resource control into three orthogonal mechanisms** rather than one
monolithic limiter:

- **Fuel** — deterministic instruction budget. `Config::consume_fuel(bool)`
  (`crates/wasmtime/src/config.rs:612`), `Store::set_fuel/get_fuel`
  (`runtime/store.rs:1041/1014`). Per-operation decrement → higher overhead →
  **opt-in**.
- **Epoch interruption** — cheap, wall-clock-agnostic interrupt.
  `Config::epoch_interruption(bool)` (`config.rs:733`), `Engine::increment_epoch`
  (`engine.rs:853`, called by an external timer thread / signal),
  `Store::set_epoch_deadline` (`store.rs:1105`), `epoch_deadline_trap`
  (`store.rs:1136`). The guest checks a **single counter** at back-edges → near
  zero overhead. **One mechanism serves both timeout and cancellation** (a timer
  thread increments for timeout; any host thread increments / sets deadline 0 for
  cancellation).
- **Store limits** — growth caps. `ResourceLimiter` (`runtime/limits.rs:32`),
  `StoreLimits`/`StoreLimitsBuilder` (`limits.rs:314/219`), `Store::limiter`
  (`store.rs:955`). Rejects `memory.grow`/`table.grow` past a ceiling.

## Decision

Adopt wasmtime's **three orthogonal mechanisms** in v2, with explicit names
(not v1-matching, per user). All live on the `Engine`/`Store`(`Instance`) config
surface, the C API (`zwasm.h`, currently empty), and thin CLI flags.

1. **Fuel** (deterministic, opt-in). A `u64` budget decremented per block/op;
   exhaustion traps `error.OutOfFuel`. Compiled behind a runtime-enable flag so
   the default hot path pays at most a predicated branch (final default decided
   by the #3a perf spike). Zig: `engine.config.consume_fuel`, `store.setFuel` /
   `store.getFuel`. C: `zwasm_config_set_consume_fuel`, `zwasm_store_set_fuel`.

2. **Epoch interruption** (cheap; timeout + cancellation). A process-global
   epoch counter; the guest compares it against a per-store deadline at
   **function entry (riding the existing JIT prologue stack-probe checkpoint) +
   loop back-edges**; over-deadline traps `error.Interrupted`. Host drives it via
   `engine.incrementEpoch()` (from a timer thread for timeout, or any thread for
   cancellation) + `store.setEpochDeadline(ticks)`. Zig: `Engine.incrementEpoch`,
   `Store.setEpochDeadline`. C: `zwasm_engine_increment_epoch`,
   `zwasm_store_set_epoch_deadline`. A built-in convenience timer may back a CLI
   `--timeout <ms>`.

3. **Store resource limits** (memory/table growth caps). Checked at
   `memory.grow`/`table.grow`; over-limit returns the spec's `-1` grow-failure
   (NOT a trap — matches wasm semantics). Zig: `Store`/`Instance` limits config
   (max memory pages, max table elements). C: `zwasm_config_set_max_memory`,
   `zwasm_config_set_max_table_elements`.

CLI thin flags (opt, not bloat): `--fuel <N>`, `--timeout <ms>` (timer-backed
epoch), `--max-memory <bytes>`. Build: the checks compile in by default; fuel's
decrement is gated by the runtime-enable flag. A `-Dinterrupt=false` escape hatch
may be added only if the spike shows unavoidable overhead.

Implementation order (per campaign): **#3a epoch** (first sub-step = perf spike
in the JIT prologue) → **#3c store-limits** → **#3b fuel**.

## Alternatives considered

### Alternative A — v1-style single monolithic checkpoint

- **Sketch**: one `Vm`-like checkpoint combining fuel + deadline + cancel flag.
- **Why rejected**: couples three independent axes into one slot
  (`single_slot_dual_meaning` smell); forces fuel's per-op cost onto the
  timeout/cancel path. wasmtime separates them precisely so epoch stays cheap and
  fuel stays opt-in. The clean design is the factored one.

### Alternative B — signal/async preemption (SIGALRM-style)

- **Sketch**: interrupt the guest via an async signal.
- **Why rejected**: not portable (Win64 has no SIGALRM; would need a parallel
  SEH/APC path), non-deterministic, and fragile inside JIT-compiled code. The
  epoch-counter poll is portable across interp + arm64/x86_64 JIT + Win64 and
  composes with the existing stack-probe checkpoint.

### Alternative C — leave all limits to the host (no built-in)

- **Sketch**: ship no interruption; embedders implement their own.
- **Why rejected**: a runtime cannot sandbox untrusted code without these;
  wasmtime/wasmer/v1 all provide them; contributors needed them (#6/#28). User
  directive: semi-mandatory. Pure-spec-core is not the chosen identity.

## Consequences

- **Positive**: production sandboxing of untrusted guests; v1 + contributor
  parity for the headline gaps; standard (wasmtime-shaped) API embedders expect.
- **Negative**: new API surface (3 configs) — mitigated by the clean orthogonal
  factoring + opt-in fuel; hot-path checks — mitigated (epoch cheap, fuel
  runtime-gated, both measured at #3a). New trap variants `error.OutOfFuel` /
  `error.Interrupted` widen the trap set (exhaustive `switch (err)` callers
  update once).
- **Neutral / follow-ups**: `src/include/zwasm.h` placeholder gets filled; CLI
  grows `--fuel`/`--timeout`/`--max-memory` (the only Tier-1 CLI additions — the
  rest stays lean per ADR-0159). `docs/migration_v1_to_v2.md` §1 rows move from
  "deferred" to "addressed" as each lands. No release implied (ADR-0156).

## References

- ROADMAP §1 (runtime mission), §3.2 (lightweight-yet-fast), §14 (no bloat)
- wasmtime: `config.rs:612/733`, `runtime/store.rs:1014/1041/1105/1136/955`,
  `engine.rs:853`, `runtime/limits.rs:32/219/314`
- v1: `~/Documents/MyProducts/zwasm/src/vm.zig` (fuel/deadline/cancelled),
  `src/c_api.zig` (`zwasm_config_set_{fuel,timeout,max_memory,cancellable}`)
- Contributor origin: DeanoC #6 (timeout), jtakakura #28 (cancellation)
- `docs/migration_v1_to_v2.md` §1; `docs/v1_contributor_history.md`
- Related ADRs: 0105 (JIT prologue stack-probe — epoch rides it), 0156 (no
  autonomous release), 0159 (lean CLI), 0070 (libc boundary — timer thread)

## Revision history

| Date | Commit | Change |
|------|--------|--------|
| 2026-06-08 | `91727cc6` | Initial draft (Accepted). Design: 3 wasmtime-aligned mechanisms — fuel · epoch counter · pre-instantiate StoreLimits. |
| 2026-06-08 | `1001fa0e`/`460210f1`/`7216e7b1`/`58479dd6` | **As-built v0 (interp engine only) — DIVERGES from the draft; recorded so the gap is future-fixable.** Shipped: (1) interruption as a **binary per-instance atomic flag** the guest polls (`Runtime.interrupt_flag_storage` + `checkInterrupt`), NOT the u64 **epoch counter** — sufficient for cancel/timeout, but no per-store deadline ticks; (2) **fuel** as `Runtime.fuel` decremented per interp instruction (matches the design); (3) memory-limit as a **post-instantiate** `Instance.setMemoryPagesLimit` folded into `growMemory`, NOT the **pre-instantiate StoreLimits config**; table-elems limit not done. ALL **interp-engine only** (the default), via the Zig facade. **Deferred follow-ons (tracked: D-314)**: JIT-engine sandboxing (interrupt/fuel/mem-cap need a host→JIT driving path + both-arch prologue codegen + a run-trap harness), the epoch-counter upgrade, the pre-instantiate StoreLimits config, table limits, the CLI/C-API surface, and `TrapKind.interrupted` in `trap_surface` (today `mapInterpTrap` → `binding_error`). |
| 2026-06-12 | (#3a-4 commit) | **#3a-4 C-API naming pinned + shipped.** Instance-level `zwasm_instance_set_fuel` / `disable_fuel` / `fuel_remaining` / `set_memory_pages_limit` / `clear_memory_pages_limit` / `interrupt` / `clear_interrupt` + `zwasm_trap_kind` (kind 16/17 as `ZWASM_TRAP_*` macros) in `include/zwasm.h` (placeholder replaced). REJECTED v1's CONFIG-level `zwasm_config_set_*`: v2's budgets are live Runtime fields, so post-instantiate per-instance setters (mirroring the Zig facade exactly) are the truthful surface and allow mid-workload re-arming; wasmtime ships both shapes, v1 only config — instance-level is the smaller honest core. C API stays interp-only (live security posture); JIT budgets are the CLI surface (`--fuel`/`--timeout`/`--max-memory`, both engines). Older undeclared zwasm_* exports → Phase-16 C-surface audit. |
| 2026-06-12 | `632ebf07` | **#3b JIT-fuel design pinned (implementation = next bundle cycle).** Granularity: **decrement-by-1 at each existing JIT poll site** (function prologue + every loop back-edge — the #3a interrupt-poll sites, fuel folds in beside them), v1-parity (`v1 x86.zig:emitFuelCheck` = `SUB [vm+fuel],1; JNS; stub` at back-edges). REJECTED: wasmtime's per-op cost tables (`cranelift/func_environ.rs` fuel_check) — needs a multi-pass cost precomputation, conflicts with P3/P6 single-pass; a linear-segment-K charging refinement (count ZIR instrs since last poll, single-pass-feasible, closer to interp parity) is a possible later upgrade, not v0. CONSEQUENCE (documented, deliberate): fuel UNITS differ per engine — interp = instructions, JIT = poll-site crossings; cross-engine fuel determinism is NOT promised (wasmtime makes no cross-version promise either); facade doc must say so. Mechanics: `JitRuntime.fuel_ptr: ?*i64` TRAILING field (null = unmetered, mirrors `interrupt_ptr`); poll = load ptr / null-skip / `SUB [ptr],1` / sign-check → **trap code 17 = `TrapKind.out_of_fuel`** (NEW kind: + `mapInterpTrap(error.OutOfFuel)` arm + `jitTrapCode(17)` + runner `trapKindName` arm per the 2026-06-06 TrapKind-widening lesson); back-edge stub POST-frame via `emitTrapExitStub(17)` / arm64 `EmitCindStub` fb=frame_bytes, prologue stub fb=0 — exact #3a stub structure. Facade `setFuel`/`fuelRemaining` + `InstantiateOpts.fuel` arm the JIT cell when engine=jit. |
| 2026-06-08 | (58479dd6-era) | **Pre-instantiate budgets in the facade `InstantiateOpts` (discharges part of the deferred StoreLimits-config follow-on).** `Module.InstantiateOpts` now carries `fuel: Budget` + `max_memory_pages: Budget` (`Budget = union(enum){ unmetered, limited: u64 }`), both defaulting to a **FINITE** value (fuel `1e9`, memory `4096` pages = 256 MiB) so the plain `init → compile → instantiate → invoke` flow is bounded without the post-instantiate setter; `.unmetered` must be spelled out. Budgets thread through `api/instance.zig::instantiateInternal` (new `InstantiateLimits` param + `instantiateFacade` entry) and are armed on the `Runtime` **before** the start function runs (fuel) and **before** the initial linear-memory allocation (`instantiateRuntime` now refuses a declared `min` above the cap → `error.MemoryLimitExceeded`, not only `memory.grow`). C ABI `wasm_instance_new` + the `Linker` path keep the unmetered default (their budget surface stays a follow-on). Still interp-engine only. |
| 2026-06-15 | `3cb5e3bf` | **Table-element limit shipped (D-332) — discharges the deferred "table limits" follow-on.** Mirrors `max_memory_pages` EXACTLY: `Module.InstantiateOpts.max_table_elements: Budget` (default FINITE `10_000_000` ≈ 80 MiB for funcref — a generous DoS backstop, NOT a low arbitrary cap like the removed 4096 of D-331(A)) → `InstantiateLimits.max_table_elements` → `Runtime.store_table_elements_max` armed in `instantiateInternal` **before** the table alloc → `instantiateRuntime` refuses a declared `min` above the cap (`error.TableLimitExceeded`, not only `table.grow`) + a distinct facade early-reject via `declaredInitialTableElements`. Closes the D-332 gap: the grow-time `store_table_elements_max` (table_ops.zig) did not cover the eager INITIAL alloc, so a pathological `(table 4e9 funcref)` OOM'd the host. Threads through the `Module` + `Linker` facade paths (both interp — the sandboxing surface). FOLLOW-ON (low value): the `--engine jit` CLI table cap (runs user-chosen files, not a sandboxing surface) + C-ABI `wasm_instance_new` host-tightening (the default backstop already protects it). |
