# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `3e8049dd` — feat(p10): opRefI31 pushes .i31ref
  (typed precision; 10.G op_gc cycle 5). Vertical i31 slice
  complete (parser+validator+lower+interp). Pre-existing interp
  + lower + i31_pack helpers + cycle 5's validator-typed-push
  form the end-to-end seam.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 18 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## 10.G-foundation bundle CLOSED (6 cycles; ~350 LOC + 19 tests)

Substrate landed for the larger 10.G WasmGC implementation:

- `e953b089` cycle 1 — Value.anyref arm + Module.needs_gc_heap field.
- `3fa32ddf` cycle 2 — parser wires needs_heap_detector.
- `e3bd30e1` cycle 3 — feature/gc/heap.zig per-Store slab (7 tests).
- `e5eed624` cycle 4 — Collector vtable + collector_null (6 tests).
- `96a17d5a` cycle 5 — Runtime.gc_heap + instantiate gate (3 tests).
- `62bebe25` cycle 6 — `-Dgc=true|false` build-option seam (1 test).

zig build test 2117/2131 (was 2099/2113 at bundle open; +18
foundation tests across 6 cycles).

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

## Active bundle

- **Bundle-ID**: 10.G-op_gc
- **Cycles-remaining**: ~19 (per `.dev/phase10_g_op_bundle_plan.md`)
- **Continuity-memo**: Cycle 1 (`3b1a4c43`) ADR-0115 §6
  amendment. Cycle 2 (`a4556584`) ValType.i31ref + 16-site
  cascade. Cycle 3 (`ccc39156`) parser readValType wires 0x6C.
  Cycle 4 (`56e1dd0b`) validator opRefNull + reftype cascade.
  Cycle 5 (`3e8049dd`) opRefI31 pushes typed .i31ref; vertical
  i31 slice complete. Cycle 6 (next): extend ValType with the
  remaining 4 GC variants (anyref 0x6E, eqref 0x6D, structref
  0x6B, arrayref 0x6A) — each is parallel to i31ref's cycle
  2-4 work but i31 is the simplest (no heap allocation). For
  the heap-allocating ones, the dispatch will need op_gc.zig
  for struct.new / struct.get / struct.set + RTT TypeInfo
  (sub-chunks 5-7 of plan).
- **Exit-condition**: wasm-3.0-assert exception-handling /
  function-references / gc corpora open for op_gc dispatch +
  at least the first i31 spec directive flips green via the
  new dispatch + heap path.

## Next sub-chunk candidates (names only)

- **10.G op_gc cycle 1: ValType extension + ADR-0115 amend**.
- **10.G op_gc cycle 2: parser readValType branches for 5 GC bytes**.
- **10.G op_gc cycle 3: validator stack-type accepts GC ValTypes**.
- **10.G op_gc cycle 4: i31 ops (ref.i31 / i31.get_s / i31.get_u)**.
- Per `.dev/phase10_g_op_bundle_plan.md` for the full 12-sub-chunk
  sequence with cycle estimates.
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
