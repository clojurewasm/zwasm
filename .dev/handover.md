# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `ea414cf0` — pin memory64 instantiate gap at address64.0
  (test-only regression marker; isolates the handover-named
  candidate). Compile path green for memory64 fixtures
  (frontendValidate memory0_idx_type plumbing live since
  `639c2916`); gap is past the c_api boundary, inside
  `instantiateRuntime`.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 17 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## Spec runner observable (HEAD `8b5b2ae1`; unchanged this cycle)

```
[memory64           ] return=337 (pass=81 fail=244) trap=205 (pass=17 fail=188) invalid=83 (pass=83 fail=0) exception=0
[tail-call          ] return=31  (pass=31 fail=0  ) trap=0   (pass=0  fail=0  ) invalid=10 (pass=10 fail=0) exception=0
[exception-handling ] return=34  (pass=0  fail=33 ) trap=2   (pass=0  fail=2  ) invalid=7  (pass=6  fail=1) exception=4 (pass=0 fail=4)
[gc                 ] (no corpus — D-179 wabt)
[function-references] return=0   (pass=0  fail=0  ) trap=0   (pass=0  fail=0  ) invalid=12 (pass=12 fail=0) exception=0
total: return pass=112 fail=277; trap pass=17 fail=190; invalid pass=111 fail=1; exception pass=0 fail=4
```

assert_invalid 111/1 — only try_table.10 remains (deep EH
catch_all_ref typing, requires exnref ValType extension).

Recent commits this resume:
- `ea414cf0` test — pin memory64 instantiate gap at address64.0.
- `24f0353f` chore — retarget handover after bulk mem ops memAddrType.
- `01de05e8` — bulk mem ops memAddrType (preemptive; no runner delta).
- `8b5b2ae1` — opMemorySize/Grow memAddrType plumb (+46 dirs).
- `a2a3ac3b` test — D-189 regression fixture correction.

## Active task — memory64 instantiate gap (bundle candidate)

This-cycle observation: address64.0.wasm compiles green but
`linker.instantiate` returns `error.InstantiateFailed`. The error
is the c_api wrapper around any `return error.<X>` site in
`runtime/instance/instantiate.zig::instantiateRuntime` (51 raise
sites; coarsely swallowed at `api/instance.zig:754` catch). Next
chunk = NARROW which specific site fires — candidates from inspect:
`MultiMemoryUnsupported` (host-allocator path for i64 memory size),
`DataSegmentOutOfRange` (active-data install on i64 memory),
plus any memory.size/grow / bulk-mem residual after the
`8b5b2ae1` + `01de05e8` plumbing landed.

Tractable per-cycle deliverable: thread a stage-name into
`instantiateRuntime`'s catch (or via `diagnostic.setDiag`) so the
underlying error name surfaces past the c_api boundary. Once the
specific raise site is named, single-cycle fixes per-fixture can
proceed against the wasm-3.0-assert memory64 corpus.

## Next sub-chunk candidates (names only)

- **memory64 instantiate gap** — current active per above.
  Multi-cycle bundle candidate when next cycle narrows the
  specific raise site.
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
