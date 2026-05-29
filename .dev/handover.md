# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc176 (impl+revert, no net src) — implemented the 3-piece
  ref.test-on-funcref fix; **piece 2 (funcref-RTT) PROVEN** (FAILval
  flipped `exp=1 got=0`→`exp=0 got=1`: expect-1 cases now pass). Reverted:
  the sole remaining gap is `canonicalEqual` being **rec-group-blind**
  (over-matches `.wast` module 378). cyc171/172/176 all shared this blind
  spot → cyc177 needs rec-group-span-aware iso-recursive equality. The
  plumbing is verified-correct (ADR-0126 cyc176 amend). cyc174
  (`cbcd081b`): start-exec → multi-mem 396. **gc 345**.
- Earlier arc: cyc147-148 ADR-0125 packed (62→116); cyc146 ADR-0016 M3
  validate self-attribution (`compile FAIL [fn= off= op=]`) + subtypeCtx
  coercion; cyc144/145 GC blocktypes + br_on_cast; cyc141 rt.datas fix
  (multi-mem→393); cyc130-140 i31/struct/array + const-expr.
- Runner EXECUTES via interp; gc_heap + gc_type_infos + rt.datas all
  materialised at instantiate. Arrays use 8-byte uniform slots
  (type_info.slot_size); data-seg elements are NATURAL width.
- **Bundle 10.E-eh-tail CLOSED** cyc120 (`5db875b0`) — EH corpus FULLY
  GREEN 34/34 (cross-module propagation + caller-frame catch; ADR-0114
  full substrate cyc110–120; D-192 EH clause PROVEN). Lesson
  `eh-cross-module-tag-substrate-scope` has the journey.
- Mac+ubuntu green through cyc142 (`OK (HEAD=a763d44a)`).

## Active bundle

- **Bundle-ID**: 10.G-wasmgc (WasmGC spec corpus — the largest
  remaining §10 gap; follows the CLOSED 10.E EH chain)
- **Cycles-remaining**: open; next = the cyc176 3-piece landing (below).
- **Continuity-memo**: substrate DONE (don't rebuild): `feature/gc/`
  heap+type_info+i31+collector, struct_ops/array_ops registered, ADR-0115/
  0116/0121/0124/0125. **VERIFY by DIRECT binary run**; M3 attributes
  every compile FAIL (`grep "compile FAIL.*op=0x"`).
- **Exit-condition**: gc return ≥ 90 **EXCEEDED (345)**. Open target:
  maximise return toward the corpus ceiling (D-198 tail = cyc176).

## Active task — cycle 177: rec-group-aware iso-recursive canonicalEqual — **NEXT**

On-bundle (10.G), HIGH blast radius. cyc176 proved the PLUMBING correct
(funcref→raw-typeidx resolution + `FuncEntity.raw_typeidx` + validator
OR-arm + equivalence-class `canonical_ids`) — piece 2 confirmed (expect-1
ref.tests 348/360 pass). The ONE remaining gap: `canonicalEqual` is
**rec-group-blind**. Full detail in ADR-0126 "cyc176 RESULT". cyc177:
1. **Retain rec-group spans at decode** — `sections.decodeTypes` add a
   per-type `rec_group_id: []u32` (or `[2]u32` start/end). Decode flattens
   `(rec …)` to consecutive indices today, discarding membership.
2. **Rec-group-aware iso-recursive `canonicalEqual`** — two types equal iff
   their whole rec groups are isomorphic: members pairwise, **intra-group**
   refs POSITIONAL (member-k-of-this-group), **inter-group** refs by
   canonical id. Standard WasmGC §3.3 canonical form. Replaces the flat
   `sections.canonicalEqual` (cyc176, reverted — over-matched).
3. **Re-apply the verified plumbing** (cyc176 reverted diff): the funcref
   resolution + raw_typeidx + validator OR-arm + canonical_ids driver are
   correct; only the equality algorithm changes.
**Bar**: `.wast` module 378 → ref.test **0** (the rec-group distinction),
348/360 → **1**, in ONE run. VERIFY FULL test-spec ALL proposals +
assert_invalid: gc invalid stays 57 (ADR-0124 decode-coupling), multi-mem
≥396, exit 0, 0 panics. Then **4th probe**: the 2 residual FAILsetup.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=345/407 trap=90/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c169
[multi-memory       ] return=396/407 trap=238/238  ← cyc174 start-exec (+3 start0)
```

> Use `--fail-detail` (reliable per-assert), NOT the per-manifest
> breakdown (over-counts gc). Real gc residuals: i31(4) + type-sub(5) +
> ref_test(2).

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
