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
