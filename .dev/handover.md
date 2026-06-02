# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — re-scoped (ADR-0133)** (Phase 9 = DONE 2026-05-24). §10 exit =
  **interp pass=fail=skip=0 (MET) + JIT 0-real-fail + every JIT skip on the forward-ref'd
  deferred-allowlist** (multi-memory-on-JIT→§14, GC-on-JIT-rooting→§11). Raw "JIT skip=0" (ADR-0128)
  was unreachable in-phase; re-scoped autonomously per ADR-0132.
- **LAST code HEAD** (`cb55013e`): **per-frame-instance unwind machinery + EH registry (ADR-0134 D2, cycle 2a).**
  `ExceptionTable.lookupByIdentity(pc, throw_id:u64)` matches a PRE-RESOLVED throw identity (from the THROWING
  table) against each frame's own table. `unwind.walk` gains an optional `InstanceResolver` (per-frame table +
  module-pc by abs pc); null result FALLS BACK to the throwing table → regression-safe with zero registrations.
  `eh_registry.zig`: process-global live-`*JitRuntime` table (fixed-cap, alloc-free per ADR-0114 D5); `resolve`
  finds the instance whose `CodeMap` contains the pc. `trampolineCore` threads the resolver. Unit-tested
  (per-frame switch, registry, control-miss). **No production change yet** (registry empty until 2b) — corpus EH
  32/2, global 794/3 unchanged. Updated the stale `unwind.zig` "Phase 11+" header.
- **D3** (`16a921a8`): global `tag_ids` (u64) cross-module identity (`TagImportTarget`/`exportedTagTarget`/
  `findExportedTagIndex`/`jitResolveTagImports`); throw+catch resolve to the same id. **Cause A** (`50e5ecd3`)
  subsumed.
- **Prior governance** (`5447cb10`): ADR-0132 (autonomous ROADMAP re-sequencing) + ADR-0133 (Phase 10 exit
  re-scope; I24; §10-scope RESOLVED). D-237 (spec-runner double-free, harness-only). **GATE TRAP**: corpus exe
  MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare `head -1` returns a STALE binary.
- **Prior (this bundle chain)**: `590093f5` JIT catchless try_table (eh_catch_entries null→empty; unblocked
  try_table.1 compile, +29 EH); `3b668110` JIT tag index space includes imported tags (validator
  StackTypeMismatch); `2b48dfdc`/`74d155b7` D-235 JIT call_indirect subtype. interp wasm-3.0 corpus FULLY
  GREEN. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`; JIT entry = `runner.zig` `JitInstance`.
- **EH-on-JIT dispatch IS wired** (lesson `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`):
  throw_trampoline.zig trampolineCore + zwasmThrowTrampoline (all 3 ABIs) set eh_handler_sp/fp/pc + JMP.
  Its docstring (lines 9-35, "3c-ii deferred") is STALE — fix when next touching. With try_table.1 now
  compiling, the dispatch RUNS — the 2 remaining fails are cross-instance (Cause B / ADR-0134).
- **Watch**: `runner_test.zig` 1370 / `compile.zig` 1223 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 (WARN, < hard 2000).

## Active task — CAUSE B cross-instance EH: **cycle 2b = thunk frame-link + registration + handler-cmap**  **NEXT**

try_table.1.wasm 32/34. ✅ D3 identity (`16a921a8`) + ✅ 2a unwind machinery (`cb55013e`, the resolver/registry).
2 fails (`catch-imported`, `imported-mismatch`) close once the registry is POPULATED + the thunk frame is
FP-linked. **2b = three pieces**:

1. **D1 thunk frame-link.** `arm64/thunk.zig` emitThunk (96B) does `STP X29,X30,[SP,#-80]!` but NOT `MOV X29,SP`
   → its frame isn't FP-linked → the FP-walk reaches the caller frame carrying a THUNK pc, not the caller's
   call-site pc. Add `MOV X29,SP` right after the STP (instr count 19→20 → pad slot consumed; `thunk_bytes`
   stays 96; ADR-offset to the literal pool 52→48; update the size/encoding asserts). x86_64 thunk = cycle 3.
2. **Registration.** Populate `eh_registry` with each live JIT instance's `*JitRuntime` once heap-pinned.
   The spec runner heap-pins exporters (jit_exporters / jit_owned) + `cur_jit`; register there +
   unregister at cleanup (the rt address is the bridge-thunk's `callee_rt`, stable). Without this the resolver
   returns null everywhere → fallback → still single-instance.
3. **Handler-cmap per instance.** `trampolineCore` on `.handler` does `cmap.lookup(handler_abs_pc)` with the
   THROWING cmap for SP-restore + landing-pad; for a cross-instance catch the handler is in module 2 → must use
   module 2's cmap. Resolve the catching instance from `handler_abs_pc` via `eh_registry` (add a helper that
   returns the rt/cmap) and use ITS cmap. Only fires once cross-instance handlers land.

Loci: `src/engine/codegen/arm64/thunk.zig` (emitThunk + asserts), `test/spec/spec_assert_runner_wasm_3_0.zig`
(register/unregister at pin/cleanup), `throw_trampoline.zig` trampolineCore (handler cmap via registry).
**Verify**: Mac JIT corpus EH dir → 34/0 (catch-imported + imported-mismatch pass). **First read**: how the
spec runner heap-pins instances (the `pp = gpa.create(JitInstanceT)` sites + cleanup loop).

Other non-gated tracks (after EH): **D-234** (memory64 assert_trap harness artifact), **D-198**, **D-209**,
**D-210** (return_call_indirect-in-try = func[36], TC+EH gap). Realworld GC/EH/TC producers.

**§10-scope: RESOLVED** (ADR-0133, this turn) — no longer user-gated. The §10 exit is re-scoped (interp
100% + JIT 0-real-fail + JIT-skip⊆deferred-allowlist). `.dev/phase10_scope_reassessment.md` is now historical
(prep doc; superseded by ADR-0133). Future cross-phase mismatches: re-sequence autonomously per ADR-0132 (no stop).

## Active bundle

- **Bundle-ID**: `10.E-eh-on-jit` (opened `3b668110`).  **Cycles-remaining**: ~2 (2b arm64 → x86_64+fixture).
- **Continuity-memo**: try_table.1.wasm 32/34. ✅ Cause A (`50e5ecd3`) → ✅ **D3 global identity (`16a921a8`)** →
  ✅ **2a unwind machinery (`cb55013e`)**: resolver+registry+lookupByIdentity, unit-tested, no prod change (registry
  empty). 🎯 NEXT = **2b**: thunk `MOV X29,SP` frame-link + REGISTER instances in `eh_registry` (spec runner pin
  sites) + handler-cmap-per-instance → catch-imported/imported-mismatch pass. func[36] = separate TC+EH gap (D-210).
- **Exit-condition**: JIT EH dir return-fail = 0 (currently pass=32 fail=2 skip=0 → target 34/0/0).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 stale u32; D-234 (51 OOB assert_trap = harness artifact).
- **10.R** function-references — corpus green; residual = D-198 + br_on_null/cast modrej (StackTypeMismatch).
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + return_call_indirect-in-try + `wasm_of_ocaml`.
- **10.E** EH — try_table.1 compiles+runs (32/34); blocker = Cause B (2 cross-instance fails) + eh_frequency runner (I20),
  c_api tag accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE; §1 + PHASE C + D-235 DONE; remaining = D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = 2a unwind machinery (`cb55013e`, code). Mac `test-all` + lint GREEN; JIT corpus re-verified (EH
32/2, global 794/3, no regression — registry empty so resolver falls back). ubuntu `test-all` kicked against the
turn HEAD — Step 0.7 next resume: `tail -3 /tmp/ubuntu.log`, revert the commit pair on FAIL. Mac aarch64; ubuntu
x86_64. Then → 2b (thunk + registration). (Prior D3 `b5b14e10` ubuntu-verified OK this turn.)

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); **pick the exe by mtime** — `/usr/bin/find .zig-cache/o -name zwasm-spec-wasm-3-0-assert
-type f -exec ls -t {} + | head -1` (bare `head -1` returns a STALE binary → masks the delta; relearned this turn).
`ZWASM_SPEC_ENGINE=jit <exe> test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Per-dir
`JIT: return pass/fail/skip` + `JITval`/`JITfail`/`JITmodrej`.

## Key refs

- ADR-0128 (Phase 10 100%); ADR-0114 (EH design — try_table/landing pads/trampoline); ADR-0119 (naked trampoline);
  ADR-0131/0126 (subtype + canonical ids, D-235). ROADMAP §10.E. `debug_jit_auto` skill for the dispatch fails.
- Debt: **D-234**, D-198 / D-209 / D-210 / D-211 / D-212.
  Lessons: `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`,
  `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks`, `2026-06-03-jit-trampoline-mid-op-clobbers-operands`.
