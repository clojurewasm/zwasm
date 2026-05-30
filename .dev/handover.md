# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — CLOSE-ELIGIBLE** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `<cyc218>`. **5 cross-feature fixtures** in `test/edge_cases/p10/cross/`:
  call_ref/return_call/EH × memory64, EH × call_ref, + cyc218 `multivalue_call_ref`→42
  (multi-value × call_ref — multi-result capture through the funcref JIT path, an untested
  interaction). All green on Mac; the 4 prior were ubuntu-verified (cyc216 `OK bb2a3471`).
- **D-206 surveyed → re-scoped + DEFERRED** (cyc218). The bundle was opened on a mis-estimate:
  the survey found the CURRENT cross-module call dispatch is INTERP-routed
  (`host_dispatch_base[i]` → `api/cross_module.zig:thunk` → `interp_mvp.invoke`; the
  `zwasm/linker.zig` Linker/CallCtx path, ADR-0109). There is NO native JIT→JIT cross-module
  bridge today — ADR-0112 D4's inline-bridge would be the FIRST, per-arch + a JIT-to-JIT
  2-module harness. ≈4-6 cycle architectural effort; NOT close-required (interp covers
  cross-module tail-call; spec corpus green). Recorded in the D-206 debt row; bundle closed.
- **I14 deferred** (cyc217): wasm.h tagtype accessors depend on the unimplemented
  type-reflection C-API family (functype/externtype) → Phase 13, not standalone 10.E.
- D-208 (cyc213) + D-209 (cyc214) fixed + ubuntu-verified. **10.P: 16 PASS / 8 SKIP / 0 FAIL**
  → close-eligible. All remaining SKIPs are deferred-to-close-cycle (I5/I11/I16/I20/I23),
  tool-gated (I21), or Phase-13 (I14). No autonomous SKIP-flip remains.
- **Step 0.7 on resume**: cyc218 added 1 fixture (multivalue_call_ref) → ubuntu kicked on
  the new HEAD. VERIFY (`tail /tmp/ubuntu.log`): the 5 cross fixtures pass on x86_64
  (FAIL ⟹ a multi-result-via-call_ref x86_64 bug; fixture-only, low-risk revert).

## Active task — call_indirect × memory64 cross fixture  **NEXT**

Continue cross-feature coverage (tractable, bug-finding-capable, close-prep). Next distinct
untested interaction: **call_indirect × memory64** — a `(table funcref)` + `call_indirect`
to a function that addresses `(memory i64 1)` (table-dispatch × memory64, distinct from the
call_ref combos). Mirror the cross/ `.wat`/`.wasm`/`.expect` convention (`runI32Export` JIT;
`wasm-tools parse`). Smallest red: the fixture, run → expected i32.
**User touchpoint (held)**: the high-value autonomous close-prep is now essentially DONE
(D-208/D-209 JIT fixes, 5 cross fixtures, caching fix, I14/D-206 scope findings). Phase 10
is close-eligible (10.P 0 FAIL); the formal close (→ Phase 11) vs grinding the deep
not-close-required work (D-206 native bridge ≈4-6 cyc; 10.G GC JIT extreme; D-198 RTT
rabbit hole) is a high-value user check-in. NOT a stop — loop continues on tractable cross
fixtures; re-arm holds.

## §10 close map

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) mature; 10.P now close-eligible (0 FAIL).
- **realworld/p10**: clang_musttail DONE (cyc201) + clang_wasm64 DONE (cyc214, JIT
  result-checked). emscripten/dart/ocaml/hoot TOOL-GATED (no toolchain).
- **gc .17** funcref-RTT (D-198) — deep defer. **funcrefs** 34/39 — 5 gated.
- **10.P close = user touchpoint** (see Open questions).

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50. Use `--fail-detail`.

## Open questions / blockers

- D-197: validate-error surfacing ad-hoc via cyc143 op-probe; permanent diag = D-197 tail.
- D-206: cross-module tail-call JIT (multi-module harness-gated). D-209: > 4 GiB memory64
  offset (payload u32) deferred.
- **User touchpoint (2026-05-30)**: **Phase 10 is NOW close-eligible (10.P 0 FAIL)** — the
  last close-blocker (D-208) + the realworld memory64 gap (D-209) are cleared. The funcref/
  tail-call JIT matrix + memory64 realworld are DONE both arches. A user check-in on
  **formally closing Phase 10 (→ Phase 11) vs continuing JIT-completeness** (D-206
  cross-module TC, 10.G GC JIT — both NOT close-required; interp covers the corpus) is
  high-value here. NOT a stop — loop continues autonomously on I3 (close-prep); re-arm holds.

## Key refs

- ADR-0111 (memory64 D4/D5); ADR-0114 (EH); ADR-0115/0116/0121 (GC); ADR-0112 (tail-call).
- `.dev/lessons/2026-05-30-jit-funcref-tail-call-codegen-recipe.md` (D-208) +
  `2026-05-30-clang-wasm-realworld-toolchain-recipe.md` (clang musttail + wasm64).
- ROADMAP §10; `.dev/phase_log/phase10.md`; `scripts/check_phase10_close_invariants.sh`.
