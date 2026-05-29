# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc193 (`d3f56f4f`) — **assert_unlinkable directive implemented**
  (runner + manifest + regen, mirror cyc184). gc/type-subtyping 8 unlinkable
  un-skipped (skip 20→12): **pass=3 fail=5**, ZERO regression (gc 349/96/60 +
  all 5 proposals unchanged; 0 panics). 3 pass verify cyc192's reject path
  (concrete-result-ref); 5 fail (`.35/.36/.42/.52/.54`) wrongly LINK — func
  types differing only in FINALITY/type-identity → **D-202** (needs cross-module
  canonical type-def compare). **Bundle 10.X CLOSED** (cyc192 positive subtyping
  + cyc193 unlinkable infra; residual = D-202).
- cyc192 (`6a77cb19`) cross-module import subtyping (.30/.48/.50 link); cyc190
  (`0f06df6e`) gc global-init type-check (invalid 57→60). All ubuntu-green.
- gc residual fails: return=1 + trap=4 = .17 rabbit hole (D-198, deep) + 5
  unlinkable (D-202). Both deep/niche/tracked. §10 close needs realworld/p10.
- Earlier arc: cyc177 iso-recursive canonicalEqual; cyc147-148 ADR-0125
  packed; cyc146 ADR-0016 M3 self-attribution; cyc130-140 i31/struct/array.
- Runner EXECUTES via interp; gc_heap + gc_type_infos + rt.datas all
  materialised at instantiate. Arrays use 8-byte uniform slots
  (type_info.slot_size); data-seg elements are NATURAL width.
- EH corpus FULLY GREEN 34/34 (ADR-0114 substrate cyc110-120; lesson
  `eh-cross-module-tag-substrate-scope` has the journey).
- Mac+ubuntu green through cyc190 (`OK` exit 0). 10.G-gc + 10.H-multimem
  CLOSED cyc188. Cross-module sharing substrate: D-199 memory + D-201 table/func.

## Active task — cycle 194: realworld/p10 clang fixtures (§10 ROW close) — **NEXT**

The gc spec-corpus is mined out to deep/niche edges (.17 = D-198; 5 unlinkable
= D-202; both tracked). The next forward §10 work is the **realworld/p10
fixtures** — the §10 ROW (10.G/10.M/10.E/10.TC/10.R) close criteria, currently
skeleton dirs (no `.wasm`). Autonomous: `clang_wasm64` (memory64) +
`clang_musttail` (tail-call) — clang✓ + wasm-tools✓ in PATH.
**cyc194 Step 0 (survey, read-only)**: (1) `test/realworld/p10/README.md` +
the existing `test/realworld/` harness (build.zig `test-realworld` /
`test-realworld-run` steps) — how a fixture is declared + run via
`cli_run.runWasm`; does it pick up p10 or need wiring? (2) Can clang target
wasm freestanding (`clang --target=wasm32 -nostdlib -Wl,--no-entry
-Wl,--export-all`) to produce a runnable no-import module with an exported
func? Verify a trivial C → `.wasm` → runs in zwasm. (3) Pick the FIRST fixture
(clang_musttail tail-call C, or clang_wasm64 >4GiB — wasm64 needs host 64-bit
+ may need large alloc, so musttail is likely simpler first).
**Bar**: land ONE real clang fixture (`.wasm` + provenance + expected) that
zwasm runs correctly, wired into a runnable test step; no regression; 0 panics.
If clang can't target wasm cleanly (no wasi-sdk / wasm target), confirm via
`clang --print-targets | grep wasm` + self-provision or debt-track per
extended_challenge; the emscripten/dart/ocaml/hoot toolchains stay gated.

## §10 close map (after this bundle)

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) are mature but ROADMAP-`[ ]`;
formal close needs realworld/p10 + 10.P. Residual after the bundle:
- **realworld/p10** (skeleton): clang_wasm64 + clang_musttail AUTONOMOUS
  (clang✓), emscripten/dart/ocaml/hoot TOOL-GATED — next major chunk.
- **gc .17** funcref-RTT (D-198 multi-mechanism rabbit hole) — deep defer.
- **funcrefs** 34/39 — 5 gated; **10.P close gate** = user touchpoint.

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20  ← cyc190 invalid-axis closed
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN (D-199/200/201 cross-module chain)
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50 (the bundle).
> Use `--fail-detail` (reliable per-assert), NOT the per-manifest breakdown.

## Open questions / blockers

- D-197: parse/validate/instantiate split DONE cyc127. Specific
  validate-error surfacing is ad-hoc via the cyc143 op-probe (lesson
  `gc-type-subtyping-is-rtt-blocked`); permanent diag emitter = D-197 tail.
- D-192: EH clause PROVEN (EH 34/34). funcrefs clause proven cyc108.

## Key refs

- ADR-0114 (EH `*TagInstance`, IMPLEMENTED cyc110–120); ADR-0115/0116/
  0121 (GC heap + type-info); ADR-0120/0123.
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (full EH journey) + `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
