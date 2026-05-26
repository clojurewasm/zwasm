# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `b04a214e` — fix(p10): instantiate active data on
  memory64 (i64.const offset). One-line dispatch fix
  (evalConstMemAddrExpr) at the data-install site moved 396
  directives green; address64.0 regression marker tightened to
  expect-success.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 17 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## Spec runner observable (HEAD `b04a214e`)

```
[memory64           ] return=337 (pass=289 fail=36 ) trap=205 (pass=205 fail=0  ) invalid=83  (pass=83  fail=0) exception=0
[tail-call          ] return=31  (pass=31  fail=0  ) trap=0   (pass=0   fail=0  ) invalid=10  (pass=10  fail=0) exception=0
[exception-handling ] return=34  (pass=0   fail=33 ) trap=2   (pass=0   fail=2  ) invalid=7   (pass=6   fail=1) exception=4 (pass=0 fail=4)
[gc                 ] (no corpus — D-179 wabt)
[function-references] return=0   (pass=0   fail=0  ) trap=0   (pass=0   fail=0  ) invalid=12  (pass=12  fail=0) exception=0
total: return pass=320 fail=69; trap pass=205 fail=2; invalid pass=111 fail=1; exception pass=0 fail=4
```

memory64 trap 188→0 (full sweep); return 244→36 fail (36 residual,
multi-value or per-fixture remaining). assert_invalid 111/1 — only
try_table.10 remains.

Recent commits this resume:
- `b04a214e` fix — instantiate active data on memory64 (+396 dirs).
- `7d815816` chore — retarget handover at memory64 instantiate gap.
- `ea414cf0` test — pin memory64 instantiate gap at address64.0.
- `24f0353f` chore — retarget handover after bulk mem ops memAddrType.
- `01de05e8` — bulk mem ops memAddrType (preemptive; no runner delta).

## Active task — memory64 residual return fails (36)

memory64 return 244→36 fail. The remaining 36 are spread across
the wasm-3.0-assert/memory64 corpus. Next sub-chunk: bisect what
shape (likely multi-value, oob trap discrimination, or per-op
codegen edge) the residuals share. Per-case investigation; can be
walked single-cycle by greping the runner for "fail" emit (after
adding a verbose mode) OR by writing a manifest-bisect test à la
the tail-call/D-187 pattern at line 790 of wasm_3_0_manifest.zig.

## Next sub-chunk candidates (names only)

- **memory64 return residual (36)** — active per above; per-case
  bisect.
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
