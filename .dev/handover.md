# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `9d6550fd` — assert_invalid + assert_malformed
  execution in wasm-3.0-spec runner. All four assertion-class
  directives now dispatched (return / trap / invalid / malformed).
  Surfaced 6 invalid-accepted gaps → D-188 (validator strictness
  in EH + function-references).
- **ROADMAP §10 progress**: 7/13 DONE (10.0/10.C9/10.J/10.F/
  10.Z/10.D/10.T), 4 IN-PROGRESS (10.M/10.R/10.TC/10.E with
  10.E core + 10.TC same-module direct + indirect + interp
  trampoline + 10.E spec runner all assertion classes wired),
  2 Pending (10.G/10.P).
- **Active debt rows**: 18 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## Spec runner per-proposal observable (HEAD `9d6550fd`)

```
[memory64           ] manifests=6 module=37 return=337 (pass=0  fail=325) trap=205 (pass=0 fail=205) invalid=83 (pass=83 fail=0)  malformed=0
[tail-call          ] manifests=1 module=3  return=31  (pass=31 fail=0 ) trap=0   (pass=0 fail=0)   invalid=10 (pass=10 fail=0)  malformed=0
[exception-handling ] manifests=1 module=4  return=34  (pass=0  fail=33) trap=2   (pass=0 fail=2)   invalid=7  (pass=6  fail=1)  malformed=0
[gc                 ] manifests=0 (no corpus — D-179 wabt)
[function-references] manifests=1 module=1  return=0   (pass=0  fail=0 ) trap=0   (pass=0 fail=0)   invalid=12 (pass=7  fail=5)  malformed=0
total: assert_return pass=31 fail=358; assert_trap pass=0 fail=207; assert_invalid pass=106 fail=6; assert_malformed pass=0 fail=0
```

Bottleneck shape: memory64 + EH module-compile gaps own most of
the return + trap fails (LoadFailed at `wasm_module_new`); fixing
those would flip ~530 directives. The invalid-side pass=106 is
mostly clean validator coverage with 6 surfaced gaps tracked by
D-188.

## Next sub-chunk candidates (names only)

- **memory64 module-compile gap** — root cause `wasm_module_new`
  ParseFailed on memory64 fixtures. Likely missing parser arms or
  validator rules for memory64 features. Would flip ~325
  assert_return + ~205 assert_trap from fail to pass — largest
  single bottleneck.
- **D-188 EH/func-refs validator strictness** — 6 invalid-accepted
  cases; per-fixture bisect for each.
- **assert_exception execution** — `exception=4` directives in EH
  manifest; needs `Exception` extraction from runtime when
  uncaught + match against expected tag/payload.
- **10.R-3** — `br_on_non_null` (unblocks 10.R-4 `call_ref` and
  10.R-5 `return_call_ref` per D-186).
- **10.G WasmGC** — large multi-cycle bundle; design plan +
  ADRs (0115/0116/0117) already shipped.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5.
- D-188 — assert_invalid validator gaps (6 cases; EH + func-refs).

## Key refs

- ADR-0017, ADR-0026, ADR-0109 (Native Zig API; this cycle
  added Instance.exportFuncSig + manifest's compileExpectInvalid),
  ADR-0111, ADR-0112, ADR-0113 §A, ADR-0114 D1/D5/D6, ADR-0119,
  ADR-0120.
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md` Row 10.T /
  10.TC / 10.E.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
