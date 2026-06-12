# ADR-0170 — Component Model + WASI Preview 2: full wasmtime-equivalent campaign

**Status**: Accepted (2026-06-07, user-directed)
**Supersedes**: the "defer-for-smaller-wins" posture in ROADMAP §15
post-v0.1.0 bullet (line ~2091) and the `proposal_watch.md` 2026-06-07
branch-hint review-log framing for CM. CM is now SCHEDULED, not gated.

## Context

The bounded-debt campaign is complete (D-301/D-303/D-231/D-302 closed,
D-279 root-caused). The next forward track is the **v0.2 本丸**: Component
Model + WASI Preview 2 — the one v1-advertised-COMPLETE surface v2 lacks.

A scoping survey (this session, building on `.dev/component_model_survey.md`
2026-06-05) measured the landscape:

- **wasmtime** is the only mature standalone CM host: ~28.7K LOC
  `runtime/component` + ~10.6K `environ/component` (≈39K, the maximalist —
  async/threading/fuel/GC included). **wasmer** has essentially no CM host
  (bets on WASIX); **wazero** none; WAMR/wasm3/wasmi none; jco is JS-transpile.
- **v1 zwasm** did a narrow-but-working CM in **5,607 LOC** (4 files, 128
  inline tests) with **zero core-VM changes**, but **no official spec corpus**
  and a P2→P1 name-map shortcut (not a full P2 host).

The original survey verdict was DEFER (no current consumer: only ClojureWasm
uses zwasm, and it needs the core Zig API/FFI, not the CM host). **The user
overrode this**: "Component Model が動くと ClojureWasm 側で主張できるのは
かなり強い" — CM-as-capability is a rare, strategic differentiator (only
wasmtime-class), valuable independent of a current consumer, and "AI は速い"
makes the time cost acceptable.

## Decision

**Build Component Model + WASI Preview 2 to wasmtime-equivalent
conformance.** Not a v1-parity checkbox or a narrow subset — the full,
spec-conformant capability, pursued as a multi-session campaign.

Constraints (the zwasm-v2 way):

1. **Spec/test-referenced, NOT copied.** Ground truth = the
   `WebAssembly/component-model` spec + its test vectors + the official
   binary/Canonical-ABI docs. wasmtime + wasm-tools are READ as references
   for SHAPE and conformance behaviour, NEVER copied (`no_copy_from_v1`
   extends to all reference repos — they are Rust + different arch anyway).
   v1 zwasm is the re-derivation textbook.
2. **Philosophy maintained.** Zone model (CM = a new Zone-2 layer above the
   core runtime, consuming `Instance`/memory as a black box — NO ZIR/ZirOp/
   `runtime.Value`/Zone restructure, per the survey). Component-level values
   kept a type DISTINCT from `runtime.Value` (`single_slot_dual_meaning`).
   Gated builds (`-Denable=component` + `-Dwasi=preview2`). TDD red→green,
   boundary fixtures, spec-citation docstrings.
3. **Proof by sample projects.** Real components built from **Rust**
   (cargo-component) and **Go** (tinygo + wit-bindgen-go) toolchains on the
   Mac `nix develop .#gen` host, committed as `.wasm`, run by the zwasm CLI
   asserting output — the "CM actually works" existence proof, mirroring the
   realworld-fixture discipline.
4. **Conformance corpus.** Distil the official component-model + WASI-P2 test
   suite into a runner (mirror `spec_assert_runner_*`) wired into `test-all`.
   "Beyond if more can be satisfied" (user) — pursue full P2 host (fs/poll/
   sockets) past the v1 P2→P1 shortcut where the spec corpus demands it.
5. **No release (ADR-0156).** The campaign never tags/cuts over. 3-host gate
   (ADR-0076) + no-copy + spike discipline all still apply.

The work sequence lives in **`.dev/component_model_plan.md`** (the campaign
driver; its §"Work sequence" supersedes ROADMAP §17 row ordering for this
campaign, close-plan-override style). ROADMAP §17 carries the high-level
tier rows; per-chunk recipes + reference chains live in the plan doc.

## Consequences

- A large new `src/feature/component/` subsystem (~v1's 5.6K LOC for Tier-1
  working; more for full P2 host + conformance). Structurally isolated:
  the core VM is the foundation it stands on, not modified.
- `src/feature/component/README.md` opens (was build-rejected post-v0.2.0).
- The ROADMAP §15 ecosystem-gate bullet is **resolved** in CM's favour by
  the capability-differentiator rationale; record there.
- This is the dominant v0.2 track; "smaller wins" (remaining_sweep / 完成形)
  become the between-chunks / gated-fallback work, not the primary track.

## References

- `.dev/component_model_plan.md` — the campaign work sequence + reference chains.
- `.dev/component_model_survey.md` (2026-06-05) — architecture survey, 4 hard
  pieces, module breakdown, WASI-P2 relationship.
- v1 textbook: `~/Documents/MyProducts/zwasm/src/{component,wit,wit_parser,canon_abi}.zig`.
- Spec: `~/Documents/OSS/WebAssembly/component-model/`; references:
  `~/Documents/OSS/wasmtime/crates/{wasmtime/src/runtime/component,environ/src/component}`,
  `~/Documents/OSS/wasm-tools/crates/{wit-parser,wit-component,wasmparser}`,
  `~/Documents/OSS/wit-bindgen/` (Go/Rust binding gen for sample projects).
- ADR-0023 (subsystem slots) · ADR-0168 (Phase 17 v0.2 line) · ADR-0156
  (no autonomous release) · `no_copy_from_v1` · `single_slot_dual_meaning`.

## Revisions

- **2026-06-13 (ADR-0182)**: the "opt-in `-Dcomponent`" posture is
  superseded — component support is DEFAULT-ON (`-Dcomponent=false` is the
  lean opt-out) after the gate-rot discovery (D-321) and the 156 KB
  measurement. See ADR-0182.
