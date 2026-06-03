# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: 15.1-gc-reclamation (GC reclamation + precise rooting — correctness-critical, non-moving)
- **Cycles-remaining**: ~2–4 (free-list reclaim → bounded-cursor test → JIT trigger D-258)
- **Continuity-memo**: **Step-0 survey DONE → `private/notes/p15-gc-survey.md`.** Collector = non-moving
  mark-sweep, sweep `collector_mark_sweep.zig:214` never frees; rooting today = conservative INTERP walk
  (`walkRootsImpl` :243) — complete for interp, but does NOT scan native JIT frames, and GC-on-JIT emits allocs
  (§10.G) → reclamation UNSAFE until a conservative native-stack scan covers JIT roots (ADR-0128 §2; NON-moving
  needs only conservative scan, NOT precise GcRootMap-emit). **SAFE incremental order**: (1) conservative
  native-stack scan rooting [strictly ADDS roots → can't cause UAF, only prevent; reuse `platform/stack_limit.zig`
  for stack bounds] → (2) free-list reuse in sweep, gated behind (1). Files: collector_mark_sweep.zig, heap.zig
  (free_lists), object_alloc.zig, root_scope.zig. ADR-0135 = rooting↔reclaim couple; no-reclaim safe interim.
- **PROGRESS**: chunk **1a DONE** `5de51a69` (`nativeStackHigh()`). chunk **1b DONE** `b46960db` —
  object-start-validated conservative native-stack scan (`scanNativeStackRoots`, gated `scan_native_stack`
  default-FALSE; enumerates real object starts via a heap walk, marks only stack words that binary-search to an
  exact start). chunk **1c DONE** `55503da7` (ADR-0146) — **production GC now collects under heap pressure**.
  Heap gained the pressure SIGNAL (`pressure_bytes`/`next_gc_at`/`gc_cycles`/`shouldCollect`/`noteCollected`);
  `root_scope.maybeCollect(heap,gti,rt)` is the DRIVER (transient stateless collector + RootScope,
  `scan_native_stack=TRUE`, mark+sweep, re-arm); wired into interp `allocateStruct`/`allocateArray`. JIT-trampoline
  trigger deferred = **D-258**.
  **NEXT = chunk 2 (free-list reuse — THE reclamation, UAF-critical)**: sweep `collector_mark_sweep.zig:212-217`
  currently counts `dead_bytes` but NEVER frees. chunk 2 pushes each dead object `(offset,size)` onto an intrusive
  free-list (dead object's own bytes store the next-free link); `object_alloc` checks the free-list before bump.
  This is where missed-root → UAF becomes REAL (now that something frees), so it is gated behind chunks 1b+1c
  (validated scan + trigger, both done). RED = interp alloc-loop (same-size, 1 live root, pressure small) →
  `heap.cursor` BOUNDED vs unbounded today. Per-exact-size first (size-class later). Files: heap.zig (free_lists),
  collector_mark_sweep.zig (sweep builds list), object_alloc.zig (reuse-before-bump).
- **Exit-condition**: free-list reuse + heap-pressure collect trigger land + an alloc-loop test shows `heap.cursor`
  BOUNDED (vs unbounded leak today) + all existing GC unit/spec tests green.

## Current state

- **Phase 15 (Performance parity with v1 + ClojureWasm) IN-PROGRESS.** Phase 14 (CI matrix) DONE
  (ADR-0145). Phase 13 (C API) DONE (ADR-0144). Phase 12 (AOT) DONE.
- **Phase 14 recap**: CI workflows (`pr`/`bench`/`bench_baseline`/`nightly`.yml — all workflow_dispatch,
  actionlint-clean, §14.5 CI-second-line) + fuzz infra (`test/fuzz/` parse/validate/instantiate crash-harness
  in test-all + the nightly smith campaign + proposal-watch + spec-bump legs). §14.P **re-scoped past D-245
  win64** (ADR-0145, same as §13.P/ADR-0144): deliverables 3-host-green (test-fuzz `0 crashes` on Mac+ubuntu+win),
  windows sole-failure = the D-245 carry. audit_scaffolding 0-block (`private/audit-2026-06-04-p14close.md`).

## Next task (autonomous)

**Work the 15.1-gc-reclamation bundle (above).** Chunks 1a + 1b + 1c done (native-stack scan + production
heap-pressure collect trigger landed). **NEXT = chunk 2** — free-list reuse, THE reclamation: sweep counts
`dead_bytes` but never frees; push dead `(offset,size)` onto an intrusive free-list, reuse-before-bump in
`object_alloc`. RED = interp alloc-loop (same-size, 1 root, small pressure) → `heap.cursor` BOUNDED vs unbounded.
**UAF-critical** (first chunk that actually frees — gated behind 1b+1c, both done). **Correctness-critical — don't
rush; small individually-verified steps.** After §15.1: §15.2 coalescer → §15.3 class-aware → §15.4 SIMD →
**§15.5 D-245 win64** (hard/remote) → §15.6 ClojureWasm. (D-258 = JIT-trampoline trigger; D-257 lesson half.)

## Step 0.7 (next resume)

This turn: §15.1 chunk 1c landed (`55503da7`, ADR-0146) — heap-pressure collect trigger + Heap signal + driver +
interp wiring + 2 tests; `zig build test` EXIT=0, lint/zone/libc/fallback green, win64 build-only cross-compile
EXIT=0, debt+adr-history gates green. **CODE changed → ubuntu kick queued this turn**; Step 0.7 next resume
verifies (`tail -3 /tmp/ubuntu.log`) — red → revert `55503da7`. Prior chunk 1b (`b46960db`) ubuntu **OK**.
**NOTE** (lesson `gate-tail-vs-exit-code`): benign `failed command: …--listen=-` / `arm64/emit: failing op` next
to a passing run = error-path test noise — the EXIT code is authoritative.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **D-257** (NOW) 20-marker `<backfill>` cohort — discharge this resume. **D-245** win64 host→JIT = §15.5
  (windows-CI/bench-green; hard remote asm). **D-255** C-API WASI io-infra (ADR-0143). **D-254** rust 3-OS
  (ADR-0142). **D-253** §13.2 host_info (cap). **D-251** WASI in AOT. **D-249** win bench timing (ADR-0137).
  **D-246** arm64 dot/extmul = §15.4. **D-238** x86_64 EH thunk. D-210/D-234/D-237/D-229/D-231/D-204/D-209/D-213.

## Key refs

- ROADMAP §15 task table (just expanded; 15.1 GC … 15.5 D-245 … 15.6 ClojureWasm). Phase Status widget
  (14 DONE / 15 IN-PROGRESS). ADR-0145 (§14.P close, re-scope-past-D-245); ADR-0135/0115/0128 (GC); ADR-0141 (§12.5).
