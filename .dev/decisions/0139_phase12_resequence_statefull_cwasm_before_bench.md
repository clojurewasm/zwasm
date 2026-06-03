# 0139 — §12.4 cold-start bench is blocked on stateful `.cwasm` execution; re-sequence Phase 12 (§12.5 first, stateful `.cwasm` as the §12.4 prerequisite)

- **Status**: Accepted (2026-06-03; autonomous re-sequencing per ADR-0132)
- **Date**: 2026-06-03
- **Author**: claude (autonomous Phase-12 re-sequencing)
- **Tags**: Phase 12, §12.4, §12.5, §12.3b, AOT, `.cwasm`, cold-start, bench, stateful, D-250, ROADMAP §18
- **Amends**: ROADMAP §12 task table (sequence + §12.4 dependency; promotes D-250 to an explicit row §12.3b)
- **Authorised-by**: ADR-0132 (autonomous cross-row re-sequence when a row's exit references genuinely-later work)

## Context

§12.4's exit is "cold-start bench-delta: AOT load+first-call vs JIT first-invocation ≥30% on **≥3 v1-class
hyperfine fixtures**." Empirical check (2026-06-03, this is the extended_challenge Step-1 confirmation):

```
zwasm compile bench/runners/wasm/shootout/gimli.wasm -o /tmp/gimli.cwasm   → exit 0
zwasm run /tmp/gimli.cwasm                                                  → Trap (exit 1)
zwasm compile bench/runners/wasm/shootout/fib2.wasm  -o /tmp/fib2.cwasm     → exit 0
zwasm run /tmp/fib2.cwasm                                                   → Trap (exit 1)
```

The `.cwasm` produces fine, but **execution traps**: the §12.1 standalone runner (`aot/run.zig`) builds a
MINIMAL STATELESS `JitRuntime` (D-250) — base pointers alias a zero pad, counts/limits 0. A real
toolchain-emitted module ALWAYS has a linear-memory section (+ usually a stack-pointer global + data
segments); its body dereferences `vm_base` / `globals_base`, which alias the zero pad → trap.

Consequence: **no v1-class fixture is stateless** (real emcc/tinygo/rustc/clang output always carries memory +
globals), so §12.4 cannot be measured on v1-class fixtures until the AOT path can run a STATEFUL module. Last
cycle (ADR-0138 close) deferred stateful `.cwasm` to D-250 as "later §12 / §12+"; this finding shows it is a
**§12.4 prerequisite**, not optional-later.

§12.5 (`.cwasm` stack-map section, gated `needs_gc_heap`, format/emission only per ADR-0117 I4) is INDEPENDENT
of stateful execution — it serialises stack-map entries the producer already has; the walker side is Phase 15.

## Decision

Re-sequence Phase 12:

1. **§12.5 proceeds next** (stack-map section) — unblocked, format/emission only.
2. **Promote D-250 → explicit row §12.3b** "stateful `.cwasm` execution": serialise module state (memory
   limits + data segments, globals + init values, tables + elem segments, imports) into the `.cwasm` (v0.3) and
   reconstruct a real runtime from the artefact alone (the AOT analogue of `setup.setupRuntime`, which today
   builds from `CompiledWasm` + `.wasm` bytes). This is the keystone that makes AOT useful for real programs.
3. **§12.4 (cold-start bench) forward-refs §12.3b** — measured on real v1-class fixtures once they run via AOT.
   The delta is dominated by compile-vs-load startup, so it is meaningful only on representative fixtures (a
   synthetic stateless toy would not be "v1-class").

New row order: 12.0 / 12.1 / 12.2 / 12.3 (done) → **12.3b (stateful, NEW)** → 12.5 (stack-map) → 12.4 (bench,
after 12.3b) → 12.P. (12.4/12.5 keep their numbers; the table is read top-to-bottom by dependency, not by the
numeric label — §12.5 sits before §12.4 in the work order.)

### Rejected alternatives

- **Measure §12.4 on synthetic stateless-void fixtures now** — not "v1-class"; a trivial function's cold-start
  delta is unrepresentative and would mark §12.4 `[x]` dishonestly.
- **Leave stateful `.cwasm` as the open-ended D-250 "§12+"** — it is provably a §12.4 blocker, so it belongs in
  Phase-12 scope, not a vague-later bucket (debt-discipline: no "later" bucket).

## Consequences

- ROADMAP §12 grows row §12.3b (stateful `.cwasm`); §12.4 row gains a "blocked-on §12.3b" note; D-250 debt row
  is deleted (promoted to §12.3b — git retains it).
- §12.3b is a multi-cycle bundle: a `.cwasm` v0.3 format (new state sections) + a runtime builder from the
  artefact. The `aot/run.zig` stateless guard is lifted when it lands.
- §12.5 is the immediate next chunk (unblocked).
- No code change in this ADR (ROADMAP + debt only).

## Update (same-day; §12.5 survey correction)

A follow-up §12.5 survey found the premise "§12.5 is unblocked" was wrong: the JIT side has **no stack-map data
yet** — `zir.GcRootMap = struct {}` is a zero-field placeholder (`src/ir/zir.zig:468`), and per-callsite
root-slot population is Phase 15 (ADR-0135/ADR-0128 §2 "rooting becomes load-bearing only when reclamation
lands"; D-211). ADR-0117 I4 asks the `.cwasm` to carry entries "in the **same shape as JIT-mode populates
them**" — but JIT-mode populates nothing, so defining the entry shape now would be speculative (guessing a
shape before its producer exists — a no-premature-design violation). So **§12.5 is Phase-15-coupled** (its entry
shape co-defines with `GcRootMap`), not the unblocked next step.

Net: BOTH remaining §12 feature rows are blocked on larger work — §12.4 on §12.3b, §12.5 on Phase-15. The single
substantive do-now row is **§12.3b (stateful `.cwasm`)**, which is the actual next work (a multi-cycle bundle).
§12.5 stays `[ ]` with a Phase-15-coupling note; a reserved-empty header slot is deferred to land WITH the
real entry shape (one format bump, not two).

> **Doc-state**: ACTIVE
