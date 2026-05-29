# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 126 (`7a44b8f4`) — parse `0x4E rec` groups (expand to
  N consecutive type indices) + **fix cyc125's backwards `0x50`/`0x4F`
  finality** (per GC ref-interp decode.ml: 0x50=sub open, 0x4F=sub
  final; corpus had MASKED the bug — see new lesson). + struct/array
  field reftype bounds. **gc ParseFailed 85→51, return 0→2, invalid
  55→57** (DIRECT binary; no regression anywhere). test+lint green.
- cyc125 (`2d88524d`) activated subtype validate (parse 0x50/0x4F +
  validateTypeSection); cyc124 (`b8248387`) validation half; cyc123
  ADR-0124; cyc122 coupling finding; cyc121 survey.
- cyc120 (`5db875b0`): cross-module EH propagation + caller-frame catch
  → **EH corpus FULLY GREEN 34/34** (bundle 10.E CLOSED; D-192 PROVEN).
- **Bundle 10.E-eh-tail CLOSED** — exit (return ≥ 33/34) met at 34/34;
  delta cyc119 (`9d5a6212`, *TagInstance: 31→32) + cyc120 (32→34).
  This completes the full EH cross-module substrate (cyc110–120,
  ADR-0114): parser→validator→instantiate-binding→*TagInstance
  identity→cross-module propagation. D-192 EH clause PROVEN.
- Mac green cyc120. ubuntu: cyc120 HEAD green (`OK (HEAD=40d7f0d0)`);
  cyc121-123 docs-only (survey/finding/ADR-0124, no kick).

## Active bundle

- **Bundle-ID**: 10.G-wasmgc (WasmGC spec corpus — the largest
  remaining §10 gap; follows the CLOSED 10.E EH chain)
- **Cycles-remaining**: ~4 (struct/array exec → RTT materialise →
  array-copy/fill → i31 exec)
- **Continuity-memo**: type-section PARSE now complete (bare/0x4F/0x50
  subtypes + 0x4E rec groups) + subtype-conformance validate (cyc124-126).
  gc ParseFailed now 51 (was 85); the remaining 51 are mostly
  EXECUTION-blocked (struct.new/array.new/ref.cast/i31 ops), not parse.
  Substrate already landed (don't rebuild): `feature/gc/`
  heap+type_info+i31+collector, validator `dispatchPrefixFB` no-RTT cut
  (~1315), ADR-0115/0116/0121/0124. The 5 invalid-accepted (struct.3/4,
  array.1/3/4 = field-access kind-check) in
  `lessons/2026-05-29-wasmgc-corpus-scope.md`. **VERIFY by DIRECT
  binary run** (zig-build stderr cache/lossy — D-197 + cache lesson).
- **Exit-condition**: gc corpus return pass ≥ 50/407 (first execution
  slice via struct/array) — refine as chunks land.

## Active task — cycle 127: GC struct/array EXECUTION — **NEXT**

Type-section parse + subtype validate are DONE (cyc124-126). The 51
remaining gc ParseFailed are mostly EXECUTION-blocked: `struct.new`/
`struct.get`/`struct.set`, `array.new`/`array.get`/`array.len`,
`ref.cast`/`ref.test`, `i31.new`/`i31.get`. Substrate already landed:
`feature/gc/` heap+type_info+i31+collector + validator `dispatchPrefixFB`
no-RTT cut (~1315). Chunk: wire the simplest execution slice first —
likely `struct.new_default` + `struct.get`/`struct.set` (heap alloc via
the landed collector) OR `i31.new`/`i31.get_s/u` (no heap). Pick by
which gc subdir has the most return fixtures gated only on that op:
survey `gc/struct/`, `gc/array/`, `gc/i31/` manifests by DIRECT binary
(check what each fails on — ParseFailed vs trap vs wrong-result). Red:
one return fixture for the chosen op family. Watch NO regression to the
57 invalid / 2 return passes. Observable: gc return pass ↑.

## Larger §10 work (later bundles)

- **Deferred funcrefs gaps** (post-EH): funcrefs return 32/39 — 1
  externref-elem (runner externref-arg parsing) + engine/cli_run
  `resolveFuncrefGlobals` (off spec-corpus path).
- **multi-memory** — return 387/407 (20 fails), trap 237/238 (1).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (cycle-120/121, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34/34 trap=2/2 invalid=7/7 exception=4/4  ✅ FULLY GREEN
[function-references] return=39(pass=32 fail=1) trap=4(pass) invalid=18(pass)
[gc                 ] return=407(pass=2 fail=382) trap=100(fail) invalid=60(pass=57 fail=3) malformed=1(pass) ParseFailed=51  ← 10.G (cyc126)
[multi-memory       ] return=407(pass=387 fail=20) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- D-197 (now-relevant at 10.G): `Engine.compile`/`frontendValidate`
  collapse specific errors to ParseFailed/bool — surfacing the real
  validate/decode error would make the gc 384-fail debugging precise.
  Discharge candidate this bundle.
- D-192: EH clause PROVEN (EH 34/34). funcrefs clause proven cyc108.

## Key refs

- ADR-0114 (EH `*TagInstance`, IMPLEMENTED cyc110–120); ADR-0115/0116/
  0121 (GC heap + type-info); ADR-0120/0123.
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (full EH journey) + `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
