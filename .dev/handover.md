# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `1e5ceb71` — fix(p10): spec runner shares Instance per
  module block (D-190 close). Dispatch loop in
  `spec_assert_runner_wasm_3_0.zig` now lifts Engine/Module/Linker/
  Instance into `cur_*` locals; three new helpers in
  `wasm_3_0_manifest.zig` take `*Instance`.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 17 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows. (D-190 discharged
  this cycle.)

## Spec runner observable (HEAD `1e5ceb71`)

```
[memory64           ] return=337 (pass=317 fail=8  ) trap=205 (pass=205 fail=0  ) invalid=83  (pass=83  fail=0) exception=0
[tail-call          ] return=31  (pass=31  fail=0  ) trap=0   (pass=0   fail=0  ) invalid=10  (pass=10  fail=0) exception=0
[exception-handling ] return=34  (pass=0   fail=33 ) trap=2   (pass=0   fail=2  ) invalid=7   (pass=6   fail=1) exception=4 (pass=0 fail=4)
[gc                 ] (no corpus — D-179 wabt)
[function-references] return=0   (pass=0   fail=0  ) trap=0   (pass=0   fail=0  ) invalid=12  (pass=12  fail=0) exception=0
total: return pass=348 fail=41; trap pass=205 fail=2; invalid pass=111 fail=1; exception pass=0 fail=4
```

memory64 return 317 (was 296 last cycle, +21); fail 8 (was 29).
Remaining 8 memory64 fails are per-fixture (residual size/grow
edge cases, load_at_zero, check-memory-zero specific cases) —
now individually tractable post-runner-refactor.

Recent commits this resume:
- `1e5ceb71` fix — spec runner shares Instance per module block (D-190 close).
- `b43cb04a` chore — retarget handover; file D-190.
- `60549a3e` fix — memory.size/grow interp idx-type-width result.
- `747de7df` chore — retarget handover after memory64 data-segment fix.
- `b04a214e` fix — instantiate active data on memory64 (+396 dirs).

## Active task — memory64 residual 8 (per-fixture investigation)

Remaining 8 memory64 return-fails. With the runner now accumulating
state, these are real per-fixture bugs (codegen edge cases, specific
load/store paths). Single-cycle bisect via the per-fail FAIL.RET
probe pattern from cycle 4 — instrument runner inline to print
fail cases, identify shape, fix, revert probe.

## Next sub-chunk candidates (names only)

- **memory64 residual 8** — active per above; per-fixture investigation.
- **EH module-compile gap** — `try_table` op validator + interp
  dispatch substrate. The 33+2+4 EH directive fails all root
  here. Multi-cycle (10.E scope).
- **D-188 final (try_table.10)** — `catch_all_ref` typing in
  try_table. Blocked-by exnref ValType extension (multi-cycle).
- **10.R-4 / 10.R-5 (call_ref / return_call_ref)** — blocked-by
  D-186 (typed-funcref Value shape ADR).
- **10.G WasmGC** — large multi-cycle bundle.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5.
- D-188 — 1 remaining (try_table.10); blocked-by 10.E validator
  + exnref ValType extension.

## Key refs

- ADR-0017, ADR-0026, ADR-0109, ADR-0111 (memory64 design),
  ADR-0112, ADR-0113 §A, ADR-0114 D1/D5/D6, ADR-0119, ADR-0120.
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md` Row 10.T /
  10.TC / 10.E / 10.M.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
