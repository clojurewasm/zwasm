# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: 10.M-D195b cycle 70 — bundle opens. Bake script now
  emits `register <as>`; manifest parser recognizes the new
  directive kind; runner counts it as a skip. `load1` re-baked
  carrying `register M`. Mac aarch64 test-all + lint green.
- **D-188 FULLY DISCHARGED** (cycle 61). **D-194 / D-195(c)**
  DISCHARGED earlier. Active debt rows: 16 — all `blocked-by:`;
  zero `now`.

## Active bundle

- **Bundle-ID**: 10.M-D195b-cross-module-register
- **Cycles-remaining**: ~2
- **Continuity-memo**: D-195 sub-gap (b) — runner-side
  cross-module `(register …)` registry. Cycle 70 (`<source>`)
  landed bake-side emission + parser recognition. Remaining:
  - **Cycle 71**: runner state — keep prior instances alive
    instead of tearing down per-module directive; on `.register
    <as>`, register the most-recent Instance under `<as>` via a
    `module_registry: StringHashMap(*Instance)`. Wire
    `Linker.defineMemory(as, export_name, instance.memory().?)`
    so a subsequent module's `(import "<as>" "<name>" memory)`
    resolves through the existing Linker findEntry path.
    Smallest red: `load1.1.wasm` instantiates without
    UnknownImport; load1's first 5 assert_returns (`invoke $M
    "read"`) still fail because invoke routing isn't wired yet
    (cycle 72).
  - **Cycle 72**: invoke routing for `assert_return $M::field
    ...` — bake script emits the `$<id>::field` syntax (or
    enriches the action JSON), parser carries the module-id,
    runner dispatches the asserts to the correct registered
    Instance (not just `cur_instance`).
- **Exit-condition**: spec runner shows `load1` fully green
  (all return + trap assertions on both the registered $M
  instance and the importing module pass).

## Active task — cycle 71: Linker.defineMemory + multi-instance lifetime

Smallest red: extend the spec runner's per-manifest loop to
maintain a `std.StringHashMap(*Instance)` of registered names →
Instance pointers. On `.register <as>`:
1. Look up the most-recent instance (`cur_instance`).
2. For each (kind=memory, name=X) export of that instance,
   call `linker.defineMemory(as, X, instance.memory().?)`.
3. Add to registry: `registry.put(as, cur_instance_ptr)` (the
   pointer outlives the loop iteration; lift teardown out of
   the per-module defer to the registry's lifetime).

Subsequent `.module` directives instantiate against the same
linker (which now carries the prior module's memory entries).
load1.1.wasm's `(import "M" "mem" memory)` resolves via the
Linker.findEntry path.

## Larger §10 work (blocked / later)

- **10.M multi-memory** — substrate cycles 62-68 + corpus 65-69
  (22 manifests / 533 passing); D-195(b) bundle (cycles 70-72)
  unblocks ~10+ remaining fixtures.
- **10.E EH** — validator side spec-correct (cycle 61); runtime
  EH dispatch + cross-module register (D-192) external-gated.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-70; unchanged from cycle-69)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[multi-memory       ] return=330(pass=309 fail=21) trap=220(pass=220 fail=0)
                      invalid=2(pass=2) malformed=2(pass=2) skip=15
[wasm-3.0-assert    ] assert_return pass=677  assert_trap pass=425  assert_invalid pass=120 fail=0
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-192 / D-195(b) — runner registry mid-bundle (cycle 70-72).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0111 (memory64 + multi-memory design).
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- `.dev/lessons/2026-05-29-gate-tail-vs-exit-code.md`.
- ROADMAP §10 row 10.M; `.dev/phase_log/phase10.md`.
