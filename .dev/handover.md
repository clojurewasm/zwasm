# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — CLOSE-ELIGIBLE** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `38afcd7a` (cyc222). **`devShells.gen` (cyc221) + 2 REAL Rust fixtures**
  (user-directed あるべき論: nix `devShells.gen` separate from `default`, kept off the
  ubuntu/windows test hosts; generated `.wasm` COMMITTED → run via the Zig edge-runner, NO
  toolchain on test hosts — `.dev/toolchain_provisioning.md`). realworld/p10 runner = 4:
  clang_musttail=15, clang_wasm64=42, `rust_loop_sum`=45 (loop, cyc221),
  `rust_fib`=55 (recursion via `#[inline(never)]` — real call/return, NOT folded; cyc222).
  **Cross-host model ubuntu-VERIFIED** (Step 0.7 `OK 369cfc91`: the rust `.wasm` ran on
  x86_64 with no rustc there). CLAUDE.md + flake.nix point at the provisioning doc.
- **7 cross fixtures** (`test/edge_cases/p10/cross/`): call_ref/return_call/EH × memory64,
  EH × call_ref, multivalue × call_ref, call_indirect × memory64, SIMD × call_ref. All Mac-green.
- D-208 (cyc213) + D-209 (cyc214) fixed + ubuntu-verified. **10.P: 16 PASS / 8 SKIP / 0 FAIL**
  → close-eligible. I14 deferred (Phase-13 type-reflection c_api); D-206 deferred (≈4-6 cyc
  native cross-module JIT bridge; existing cross-module dispatch is interp-routed; not close-required).
- **Step 0.7 on resume**: cyc222 added `rust_fib` (`38afcd7a`) → ubuntu kicked. VERIFY
  (`tail /tmp/ubuntu.log`): rust_fib (+ the rest) pass on x86_64 (committed `.wasm`, no rustc
  on ubuntu). FAIL ⟹ a rust-recursion x86_64 codegen miscompile → investigate (high value).

## Active task — tinygo → wasip1 realworld fixture (broaden toolchain) via diff_runner  **NEXT**

Branch from rust to a DIFFERENT, harder toolchain for broader real-world validation. `tinygo`
is in `devShells.gen`. A `tinygo build -target=wasip1` module has a real (small) runtime + WASI
calls → it CANNOT use the no-WASI `runI32Export` edge-runner; it belongs in
`test/realworld/wasm/` under the **diff_runner** (`zig build test-realworld-diff`, byte-diffs
stdout vs `wasmtime run`; wasmtime is in `default`). Step 0: survey the diff_runner corpus
conventions (how a `.wasm` is added to `test/realworld/wasm/`, provenance, the MATCH/MISMATCH/
SKIP-WASI categories). Smallest red: a tinygo "print a constant" → stdout; run via diff_runner;
MATCH vs wasmtime. A MISMATCH or SKIP-WASI is a real finding (WASI gap / miscompile). Prefer
tinygo over full `go` first (go's runtime is ~MB; tinygo is lean). Follow-on: emcc
`-sMEMORY64=1` big-alloc (lazy emcc cache builds on first use).
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
