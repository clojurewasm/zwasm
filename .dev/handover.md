# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `96a17d5a` — feat(p10): Runtime.gc_heap +
  instantiate-side gate (10.G-foundation cycle 5; ADR-0115 §1).
  Closes the 10.G-foundation bundle's exit-condition (instantiate
  consumes Module.needs_gc_heap to materialise Heap iff true).
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 18 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## 10.G-foundation bundle CLOSED (5 cycles; ~310 LOC + 18 tests)

Substrate landed for the larger 10.G WasmGC implementation:

- `e953b089` cycle 1 — Value.anyref arm + Module.needs_gc_heap field.
- `3fa32ddf` cycle 2 — parser wires needs_heap_detector.
- `e3bd30e1` cycle 3 — feature/gc/heap.zig per-Store slab (7 tests).
- `e5eed624` cycle 4 — Collector vtable + collector_null (6 tests).
- `96a17d5a` cycle 5 — Runtime.gc_heap + instantiate gate (3 tests).

zig build test 2116/2130 (was 2099/2113 at bundle open; +17
foundation tests + +1 wire test in parser at cycle 2).

What's NOT yet in place (post-foundation, future bundles):
- GC valtype parser/validator (anyref/eqref/structref/arrayref/
  i31ref enum variants + decoder branches).
- op_gc.zig dispatch (struct.new / struct.get / struct.set /
  array.* / ref.test / ref.cast / br_on_cast).
- collector_mark_sweep.zig (β must-ship per ADR-0115 §10).
- `-Dgc-collector={null,mark_sweep}` build-option dispatch.
- Root walker (Mode A `zwasm_runtime_with_root_scope` per §4).
- regalloc stack-map axis (ADR-0113 §C / ADR-0115 §7).

## Spec runner observable (HEAD `96a17d5a`; unchanged)

```
[memory64           ] return=337 (pass=337 fail=0  ) trap=205 (pass=205 fail=0  ) invalid=83  (pass=83  fail=0) skip=0
[tail-call          ] return=31  (pass=31  fail=0  ) trap=0   (pass=0   fail=0  ) invalid=10  (pass=10  fail=0)
[exception-handling ] return=34  (pass=0   fail=34 ) trap=2   (pass=0   fail=2  ) invalid=7   (pass=5   fail=2  ) exception=4 (pass=0 fail=4)
[function-references] invalid=12  (pass=12  fail=0)
total: return pass=368 fail=34; trap pass=205 fail=2; invalid pass=110 fail=2; exception pass=0 fail=4
```

Foundation cycles produce no spec-runner delta — they substrate
future op_gc consumers. EH 40 fails still gated on the bigger
10.G work (per D-192).

## Active task — survey for next tractable §10 work

Foundation closed; next move requires choosing a parent bundle:
(A) GC valtype parser+validator extensions (cycle ~6-10 of larger
10.G impl), OR (B) opportunistic wait for user touchpoint on
ADR-0120 / Phase 10 close prep / D-179 wabt bump.

(A) is autonomous-eligible. (B) is bucket-3 territory if no
single-cycle work remains.

## Next sub-chunk candidates (names only)

- **10.G op_gc impl bundle (parent of foundation)** — GC
  valtype enum extensions + parser/validator + op_gc.zig
  dispatch + collector_mark_sweep impl. Multi-cycle, large.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl (now substrate
  in place; ops layer is next bundle).
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5 (GC-gated).
- D-188 — 2 now (try_table.8 + try_table.10); blocked-by 10.E
  validator strictness (GC-gated via D-192).
- D-192 — EH runtime path blocked-by exnref ValType + cross-module
  register support (GC-gated).

## Key refs

- ADR-0017, ADR-0026, ADR-0109, ADR-0111 (memory64),
  ADR-0112, ADR-0113 §A/§B/§C, ADR-0114, ADR-0115 (GC heap;
  cycles 1-5 implement §1+§3+§5+§6+§10), ADR-0116 (GC roots
  + RTT + i31), ADR-0117, ADR-0119, ADR-0120.
- ROADMAP §10 row 10.G; Phase log `.dev/phase_log/phase10.md`.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
