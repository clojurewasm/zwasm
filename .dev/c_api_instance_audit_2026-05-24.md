# c_api Instance lifecycle audit (D-139)

> **Doc-state**: ACTIVE — load-bearing for Phase 9 §9.13-0 close
> (D-139 discharge per [`phase9_close_master.md`](./phase9_close_master.md) §5.3a Phase A2).
> Filed 2026-05-24 cycle (post-§9.13-V merge, post-D-167 close).

## §1 — Purpose

Discharge D-139 = "c_api Instance lifecycle audit + paired
in-source tests" per close-master §5.3a Phase A2. spec_assert
bypasses the c_api `wasm_instance_new` / `setupRuntime` path,
so spec-corpus coverage doesn't exercise c_api Instance
behaviours (zombie list, arena ownership, cross-module Store
binding). Approach: **(b) add per-c_api-feature in-source
fixtures** in `src/api/instance.zig` (not (a) reroute
spec_assert).

## §2 — Existing coverage (as of cycle baseline)

`src/api/instance.zig` carries **31 in-source `test "..."`
blocks** lines 946–1787. Phase 9 I2 invariant baseline (per
`scripts/check_phase9_close_invariants.sh` I2):

| Block | Lines | Scope                              |
|-------|-------|------------------------------------|
| `wasm 2.0 reftype c_api round-trip`              | 1455–1482 | Funcref param+result, single instance |
| `wasm 2.0 bulk-traps via c_api: memory.copy OOB` | 1503–1560 | Trap lifecycle, single instance       |
| `wasm 2.0 mixed-exports c_api walk`              | 1561–1596 | Func+Memory+Table+Global exports cast |
| `wasm 2.0 cross-module funcref via wasm_instance_new` | 1635–1686 | Two-instance import resolution |
| `wasm 2.0 c_api arena ownership: 4 instances of same module` | 1692–1732 | 4-instance independent arena cleanup |
| `wasm 2.0 c_api zombie lifecycle: B holds funcref into A after delete(A)` | 1734–1787 | Zombie keep-alive baseline |

## §3 — Gap inventory (10 gaps; 6 unblocked, 4 blocked)

### Category A — Zombie list (cross-instance shared storage survival)

- **A1**. `"wasm 2.0 c_api zombie with mutable global: B reads
  A's global after wasm_instance_delete(A)"` — exercises
  cross-module global mutation across zombie. **Blocked on
  scalar c_api accessor completion** (D-171): needs
  `wasm_extern_as_global` + `wasm_global_get/set` for i32/i64/
  f32/f64 (spec-standard per `include/wasm.h:452-459`, industry
  exposes these in wasmtime + wasmer). v128 mutable-global case
  is permanently NOT in c_api per spec (`wasm_val_t` lacks
  128-bit slot) — Zig-side v128 via ADR-0109 native API only,
  per `2026-05-24-c_api-v128-spec-boundary.md`. Test target =
  scalar mutable global only.
- **A2**. `"wasm 2.0 c_api zombie transitive: 3-instance
  diamond funcref graph survives delete order A→C→B"` —
  multi-zombie park + transitive import chain.
- **A3**. `"wasm 2.0 c_api zombie partial-init: element-
  segment trap parks C's arena; B's imports into C still valid"`
  — `instantiateRuntime` trap-path zombie append.

### Category B — Arena ownership (cross-instance aliasing)

- **B1**. `"wasm 2.0 c_api arena ownership: table alias across
  3 instances; cross-instance table.set visible to all"` —
  **Blocked on c_api accessor completion** (D-172): needs
  `wasm_extern_as_table` + `wasm_table_get/set/size/grow`
  (spec-standard per `include/wasm.h:483-497`, industry
  standard). NOT v0.1.0 RC blocked; normal spec-completion work.
- **B2**. `"wasm 2.0 c_api arena ownership: memory alias across
  3 instances; memory.copy cross-instance visible"` —
  **Blocked on c_api accessor completion** (D-173): needs
  `wasm_extern_as_memory` + `wasm_memory_data/data_size/size/grow`
  (spec-standard per `include/wasm.h:471-481`, industry
  standard). NOT v0.1.0 RC blocked; normal spec-completion work.
- **B3**. `"wasm 2.0 c_api arena ownership: reverse-order
  delete (B then A) from forward-order instantiate"` — arena
  deinit order independence.

### Category C — Cross-module Store binding

- **C1**. Host-import registry. **Defer** to Cat III runner
  harness scope (not c_api-specific).
- **C2**. `"wasm 2.0 c_api cross-module Store binding: multiple
  stores on same engine are isolated"` — Store isolation +
  cross-store import rejection.
- **C3**. `"wasm 2.0 c_api cross-module Store binding:
  wasm_store_delete while live instance exists (cleanup order)"`
  — Store teardown safety.
- **C4**. `"wasm 2.0 c_api cross-module Store binding: engine-
  allocator survives store deinit; new store on same engine
  works"` — Engine reuse across multi-Store lifecycles.

## §4 — Discharge plan

| Cycle    | Action                                                |
|----------|-------------------------------------------------------|
| this     | File this audit + add **C2** (multi-store isolation) test. File 3 new debt rows (A1 / B1 / B2) for blocked gaps. |
| next     | Add **A2** (transitive diamond) + **B3** (reverse-order arena delete). |
| then     | Add **A3** (partial-init trap zombie) + **C3** (store_delete safety) + **C4** (engine reuse). |
| then     | D-139 close commit (`chore(debt): close D-139 ...`). |

Each chunk is `test-only` per LOOP.md classification — Mac+ubuntu
gate per chunk; windowsmini at Phase boundary. No new public API
introduced (only test consumers of existing c_api surface), so
ADR not required.

## §5 — Sources

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a
  Phase A2 (D-139 close criteria).
- ADR-0014 §6.K (cross-instance Runtime / zombie contract).
- `src/api/instance.zig` (31 existing test blocks).
- `src/runtime/store.zig` lines 59 (`zombies` list) + 72
  (`instances` registry).
- `src/runtime/runtime.zig` lines 96–180 (Runtime struct +
  `globals: []*Value` indirection).
- `include/wasm.h` + `~/Documents/OSS/wasm-c-api/include/wasm.h`
  (c_api surface).

## §6 — Revision history

- 2026-05-24 — Initial draft post-§9.13-V merge, post-D-167
  close. Audit subagent inventory + gap classification.
- 2026-05-24 — **D-139 close**. All 10 gaps landed or filed:
  - **Landed in `src/api/instance.zig`**: C2 (`64c2378c`),
    A2 (`38e31003`), B3 (`034878b6`), C4 (`288691ed`),
    C3 (`57039f10` via D-174 cascade fix), A3 (this commit).
  - **Filed as new debts** (`now`, blocked on **spec-standard c_api
    accessor completion** per industry audit `2026-05-24-c_api-v128-
    spec-boundary.md`): D-171 (A1 scalar-global accessors;
    `include/wasm.h:452-459`), D-172 (B1 table accessors;
    `include/wasm.h:483-497`), D-173 (B2 memory accessors;
    `include/wasm.h:471-481`). All three are NOT v0.1.0 RC blocked —
    they are normal wasm-c-api spec completion (matches what
    wasmtime + wasmer expose). v128 paths permanently excluded
    from c_api per spec (`wasm_val_t` lacks 128-bit slot).
  - **A2 simplification**: simpler multi-consumer pattern
    landed instead of full transitive C→A→B diamond; deferred
    to D-075 v0.1.0 RC.
  - **A3 simplification**: OOB element-segment trap landed
    instead of full partial-init element-segment writes-then-
    trap with cross-module table imports; deferred to D-075.
  - **C1 deferred**: host-import registry is Cat III runner
    harness scope, not c_api-specific.
  Final coverage: 7 new in-source test blocks under "D-139
  §5.3a A2" comment block lines 1688-1989 in `src/api/instance.zig`.
- 2026-05-24 — **Reframe per industry audit** (lesson
  `2026-05-24-c_api-v128-spec-boundary.md`). Gaps A1/B1/B2's
  "v0.1.0 RC blocked" framing in earlier revision history
  reframed: spec-standard scalar accessors are normal completion
  work (D-171/172/173 now `Status: now`). v128 paths permanently
  excluded from c_api per spec — Zig-side via ADR-0109 native API.
