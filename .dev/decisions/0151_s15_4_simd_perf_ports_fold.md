# 0151 — §15.4 SIMD perf ports (W43/W44/W45) fold to §15.P after measurement

- **Status**: Accepted (2026-06-04; autonomous-with-ADR, executing §15.4's measure-first plan)
- **Date**: 2026-06-04
- **Author**: claude (autonomous, /continue §15.4 perf assessment)
- **Tags**: Phase 15, perf, SIMD, W43, W44, W45, addr-cache, loop-persistence, measure-first, ADR-0149, ADR-0150
- **Amends**: ROADMAP §15.4 row (perf-port deliverable) + §15.P (adds the W45 loop measurement).
  Sibling to ADR-0149 (§15.2) + ADR-0150 (§15.3) — same measure-first fold pattern.

## Context

§15.4 = D-246 coverage (DONE, `1029e5b4`: 26 arm64 SIMD ops closed) + v1 SIMD perf ports
W43 (v128 base-addr cache), W44 (SIMD reg class), W45 (SIMD loop persistence), measure-first
per ADR-0149/0150 lesson. Assessment this turn (v1-source read + v2-equivalent check + bench):

- **W43** — v1 cached `vm_ptr + offsetof(simd_v128)` in a pinned reg (v1-claimed ~10-20%
  wall-clock SIMD-heavy). v2 does NOT cache it (`arm64/x86_64 op_simd.v128MemPrologue`
  recomputes the effective address every v128 load/store; the `simd_base_special` RegClass +
  `simd_base_cache_layout` are EMPTY scaffolding, `CacheLayout = struct {}`).
- **W44** — v1's second reg class keeping v128 values in vector regs across ops (v1-claimed
  30-50%, but throttled by loop-header eviction until W45). v2 already HAS an fp/v128 reg class
  (D-036, V16-V28, `max_reg_slots_fp=13`) — but spills each SIMD result to `simd_v128[]` +
  reloads, so the cross-op residency piece is absent.
- **W45** — v1's loop-header eviction skip (back-edge detection) keeping v128 locals across
  iterations; v1's HEADLINE lever ("78x→10x" vs wasmtime on a SIMD loop) — and v1 NEVER built
  it (still `[ ]` in v1's checklist). v2 is greedy-local single-pass with no back-edge
  awareness → SIMD loop locals reload from the spill slot each iteration.

Measurement: the §11.3 profile already put v2 SIMD per-op at **0.5-0.8× the
wasmtime/wazero/wasmer median** (0/12 ops lag >3×) — v2 is already faster than the optimizing
comparators per-op. Steady-state `f32x4_add` bench is startup-confounded (stddev 5.30 on 9ms).

## Decision

**Fold all three perf ports to §15.P** (opportunistic), per §15.4's stated measure-first plan.

- **W43** → fold: redundancy real but v2 already below the comparator median; headroom under the
  >3× measurable-win bar. The empty `simd_base_special` scaffolding can host it cheaply IF a gap
  ever appears.
- **W44** → already-done (the class, D-036) / fold (the residency — no spill traffic the profile
  shows mattering).
- **W45** → fold, BUT do NOT silently drop it. It is v1's biggest claimed lever and v2 genuinely
  lacks it; building it = loop-aware liveness extension across back-edges in a single-pass
  allocator (a LARGE structural change). v2 is already faster than wasmtime per-op, so the "78x"
  pathology that motivated v1's W45 does not reproduce on this corpus. **§15.P gets a concrete
  validation step**: a loop-isolated measurement (≥50M iters on a v128-local-carrying loop, or
  no-op-module baseline subtraction) — if v2's per-iteration v128-reload turns out to dominate a
  long loop (v2 lagging v1/wasmtime there), W45 is reconsidered THEN with the data.

## Rejected alternatives

- **Build W43/W45 speculatively** — measure-first lesson (ADR-0149): a benched-then-reverted
  experiment ≪ a large structural change for unmeasurable headroom. W45 especially is a major
  allocator change for a pathology that does not reproduce.

## Consequences

- §15.4 closes `[x]` (D-246 coverage done; perf ports measured-thin → folded). §15.5 (D-245
  win64, hard/remote) is next. The regalloc/SIMD-emit perf axis is now fully assessed (§15.2 +
  §15.3 + §15.4 all measured → v2 already competitive); Phase-15 perf parity rests on the §15.P
  parity-vs-v1 validation (with the W45 loop-isolated measurement as a named step).
