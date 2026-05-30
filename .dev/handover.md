# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — CLOSE-ELIGIBLE** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `eddb4652` (cyc224). **Real-toolchain realworld fixtures + a real harness bug fix.**
  nix `devShells.gen` (cyc221, user-directed あるべき論; separate from `default` so test hosts
  stay lean; generated `.wasm` COMMITTED → run via the Zig edge-runner, NO toolchain there;
  `.dev/toolchain_provisioning.md`). realworld/p10 runner = 5: clang_musttail=15, clang_wasm64=42,
  rust_loop_sum=45 (loop), rust_fib=55 (recursion), **rust_data=31** (static-array sum + shadow
  stack). **rust_data surfaced + fixed a real harness bug** (`eddb4652`): `setupRuntime` left
  defined globals at 0 instead of evaluating their init-exprs → `__stack_pointer`=0 → shadow-stack
  `SP-n` wrapped OOB → trap. Fix evaluates const global inits → **shadow-stack modules now run**
  (real `-O` rust/clang code, not just trivial fixtures). The clang-recipe lesson's "-O0
  shadow-stack traps" limitation is lifted. Cross-host model ubuntu-verified (cyc222 `OK 36547ac2`).
- **7 cross fixtures** (`test/edge_cases/p10/cross/`): call_ref/return_call/EH × memory64,
  EH × call_ref, multivalue × call_ref, call_indirect × memory64, SIMD × call_ref. All Mac-green.
- D-208 (cyc213) + D-209 (cyc214) fixed + ubuntu-verified. **10.P: 16 PASS / 8 SKIP / 0 FAIL**
  → close-eligible. I14 deferred (Phase-13 type-reflection c_api); D-206 deferred (≈4-6 cyc
  native cross-module JIT bridge; existing cross-module dispatch is interp-routed; not close-required).
- cyc223: caching fix → realworld/wasm runners (`f424d7e8`). cyc224: setupRuntime global-init
  fix → shadow-stack unlocked + rust_data (`eddb4652`, ubuntu-verified `OK c05eb57c`).
  cyc225: `rust_bubble_sort`=4 (real algorithm: nested loops + array load/store on the shadow
  stack — confirms the unlock handles real rustc algorithmic codegen; `9e4d0cfe`). realworld/p10
  = 6 fixtures, all green. **Stale-exe pitfall** recurs: isolated `find`-by-grep can grab a
  pre-fix exe → use `zig build` EXIT + the exe passing `data_sum=31`.
- cyc226: `clang_O0_arr_sum`=39 — clang `-O0` (heaviest shadow-stack spill, no regalloc) runs →
  validates the cyc224 unlock for clang too; lesson "-O0 traps" claim lifted (`0e78ecf8`).
  realworld/p10 = 7 fixtures (rust loop/recursion/data/sort + clang musttail/wasm64/-O0), all green.
- **Step 0.7 on resume**: cyc226 added clang_O0_arr_sum (`0e78ecf8`) → ubuntu kicked. VERIFY
  (`tail /tmp/ubuntu.log`): 7 realworld/p10 pass on x86_64.

## Active task — clang `-O0` floating-point fixture (last matrix cell)  **NEXT**

The rust/clang × control-flow/memory/algorithm/shadow-stack matrix is nearly complete; the one
distinct codegen cell left is **floating-point**. Gen via `nix develop .#gen`: a C `int test(){
double x=...; ... return (int)(x*...); }` at `-O0` → real f64 load/store (shadow stack) + f64
arith + f64→i32 trunc. Land `test/realworld/p10/clang_O0_fp/`; run → known i32. wasmtime-confirm.
**After this, the realworld-fixture vein is comprehensively explored** (2 real finds: D-209
LEB, global-init/shadow-stack; the rest validate real-toolchain codegen, which the spec corpus
already covers → low marginal bug-rate). 
**User touchpoint (PROMINENT — decision point)**: Phase 10 close-eligible (10.P 0 FAIL). The
high-value autonomous work (JIT bug fixes, the user-directed gen-shell + shadow-stack unlock,
the realworld matrix) is DONE. The substantive remaining is DEEP + not-close-required (D-206
cross-module bridge ≈4-6 cyc; 10.G GC JIT extreme) OR Phase-11-scoped (10 SKIP-WASI). The
formal Phase-10 close (→ Phase 11) is the genuinely highest-value next step and is a user
project-direction decision. **Next-cycle-after-fp: either engage D-206 (deep) or surface the
close decision.** NOT a stop now; re-arm holds.
**User touchpoint (held, prominent)**: Phase 10 close-eligible (10.P 0 FAIL). The real-toolchain
fixture vein is now PRODUCTIVE again (shadow-stack unlocked → real code finds real bugs, e.g.
cyc224). Deep not-close-required work (D-206 ≈4-6 cyc; 10.G GC JIT extreme) + the 10 SKIP-WASI
(Phase 11) stay deferred. The formal Phase-10 close (→ Phase 11) is a user project-direction
decision worth a check-in. NOT a stop; re-arm holds.
**User touchpoint (held)**: Phase 10 close-eligible (10.P 0 FAIL); formal close (→ Phase 11)
is a user project-direction decision worth a check-in. Tractable autonomous vein =
real-toolchain realworld fixtures (now unblocked). Deep not-close-required work (D-206, 10.G
GC JIT) stays deferred. NOT a stop; re-arm holds.

## §10 close map

Spec-corpus rows mature; 10.P close-eligible (0 FAIL). realworld/p10: clang_musttail +
clang_wasm64 + rust_loop_sum landed; go/tinygo/emcc are follow-ons (gen shell ready).
gc .17 funcref-RTT (D-198) deep defer; funcrefs 34/39 (5 RTT-gated). 10.P close = user touchpoint.

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20
[multi-memory       ] return=407/407 trap=244/244
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50. Use `--fail-detail`.

## Open questions / blockers

- D-197 (validate-error surfacing ad-hoc); D-206 (cross-module TC, deferred); D-209 residual
  (>4GiB memory64 offset, payload u32, deferred); I14 (c_api type-reflection → Phase 13).
- **Realworld toolchains**: `nix develop .#gen` (Mac only). `.dev/toolchain_provisioning.md`.

## Key refs

- ADR-0111 (memory64); ADR-0114 (EH); ADR-0112 (tail-call). `flake.nix` `devShells.gen`.
- Lessons: `2026-05-30-{jit-funcref-tail-call-codegen-recipe, clang-wasm-realworld-toolchain-recipe,
  edge-runner-fixture-cache-false-coverage}`. ROADMAP §10; `.dev/phase_log/phase10.md`.
