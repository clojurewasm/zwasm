# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 112 (`64315609`) — EH parse blocker #1 CLEARED:
  `ValType.exnref` + `readValType` bare-`0x69` arm. try_table.1's Type
  section (catch_ref result tuples `(i32, exnref)` = `7f 69`) now
  decodes. No exhaustive-switch cascade (alias over existing `.exn`
  AbstractHeapType). Mac test+lint green; no spec-corpus regression
  (5 non-EH proposals unchanged, direct-binary run). try_table.1/.5
  STILL `ParseFailed` — now at blocker #2 (module-defined Tag section
  id 13), cycle 113.
- Prior: 111 CORRECTION (cycle-110's "→ INSTANTIATE" was a stale
  run-step-cache misread; blocker is parse-side — `f5884d31`); 110 EH
  ImportKind.tag (`447c1048`, was unreachable until cyc112); 108
  ref.func global-init → funcrefs 24→32.
- Mac test+lint green at cycle 112. ubuntu: cycle-110 HEAD green
  (`OK (HEAD=e71677c8)`); cyc111 docs-only; cyc112 kick backgrounded.

## Active bundle

- **Bundle-ID**: 10.E-xmodule-tags (EH cross-module, ADR-0114)
- **Cycles-remaining**: ~5 (blocker #1 exnref cleared cyc112; #2 Tag
  section next, then instantiate + execution-side)
- **Continuity-memo**: try_table.1 PARSE blockers, in section-decode
  order (earliest wins; Type=1 first): **(1) bare exnref `0x69`** —
  DONE cyc112 (`ValType.exnref` + readValType arm). **(2) module Tag
  section (id 13)** — try_table.1 DEFINES 7 tags (`0d 0f 07 …` at byte
  ~0x94, after Memory id 5, before Export id 7), distinct from the tag
  IMPORT; **NEXT (cyc113)**. (3) ImportKind.tag — DONE cyc110, reached
  only after 1+2. Then execution-side: instantiate tag binding →
  `*TagInstance` (ADR-0114) → pointer-identity throw/catch → JIT. Full
  chain in `lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`.
  **VERIFY runner deltas by running the BINARY DIRECTLY** (zig-build
  stderr is cache/lossy — see `2026-05-29-zig-run-step-cache-stale-diag`).
- **Exit-condition**: exception-handling try_table corpus return pass
  ≥ 5/34 (currently 0/34).

## Active task — cycle 113: module-defined Tag section (id 13) decode

try_table.1 now ParseFails at its Tag section (id 13): `0d 0f 07 …`
(7 tags). Survey: is there a `decodeTags`/section-13 arm at all? (cyc110
added the tag IMPORT in section 2 + the `tag` EXPORT filter, NOT the Tag
SECTION.) Smallest red test: `decodeTags` (new or existing) on
`07 00 00 00 00 00 00 00 …` (count=7, each `attr=0x00 typeidx`) yields 7
tag typeidxs; wire it into the section dispatcher (likely
`parse/sections.zig` + the Module's tag list). Spec: Wasm 3.0 EH §5.5.x
(tag section = vec of `(attribute=0x00, typeidx)`). Observable: rerun the
runner BINARY DIRECTLY (`/tmp/c<NN>` cache + `/bin/ls -t` binary); the
EH `compile FAIL: ParseFailed` for try_table.1 should advance past the
Tag section (toward Code/validate). If a `TagSection`/`module.tags`
storage shape is an ADR-grade choice, file first; otherwise mirror the
existing section-decode pattern. Deviation watch: touching §4 (ZirOp /
runtime shape) for `*TagInstance` is later (execution-side) — this cycle
is parse-only.

## Larger §10 work (later bundles)

- **10.E EH execution** (post-parse) — `*TagInstance` identity match +
  JIT throw/throw_ref emit (`arm64/emit.zig:1172`).
- **10.G WasmGC** — corpus baked impl=0%; ZIR ops + heap + subtype
  lattice (refines `valTypeIsSubtypeFree`'s pre-GC assumption). Many
  gc/* still `compile FAIL: ParseFailed` (shares exnref/ref decode).
- **Deferred funcrefs gaps** (post-EH): engine/cli_run
  `resolveFuncrefGlobals` unwired; externref-elem runner arg parsing.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (cycle-112, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
   └─ try_table.0+.2 INSTANTIATE; try_table.1+.5 compile FAIL:ParseFailed
      → 33 asserts NO-CURINST + 1 InvokeFailed (imported-mismatch).
[function-references] return=39(pass=32 fail=1) trap=4(pass) invalid=18(pass) ParseFailed=0
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5)
[multi-memory       ] return=407(pass=387 fail=20) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- ADR-0120 / ADR-0123: Accepted; impl autonomous.
- D-192: funcrefs clause PROVEN. EH clause = bundle 10.E (now
  parse-side first: exnref ValType → Tag section → instantiate → exec).

## Key refs

- ADR-0114 (EH design — `*TagInstance`); ADR-0120 (EH payload);
  ADR-0123 (typed-ref).
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (corrected blocker chain) + `2026-05-29-zig-run-step-cache-stale-diag.md`
  (direct-binary-run discipline).
- ROADMAP §10; `.dev/phase_log/phase10.md`.
