# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 88 — spec-corpus expansion survey. Filed lesson
  `2026-05-28-spec-corpus-expansion-exhausted.md`: no autonomous
  corpus-expansion candidates remain across §10 corpora. All forward
  spec-runner-observable yield is structurally gated on ADR-0120 /
  ADR-0123 Accept or D-179 wabt upgrade.
- Active debt rows: **18** — all `blocked-by:`; zero `now`.
- Mac aarch64 test-all + lint green at HEAD prior to this chunk
  (52d9c784); ubuntu kick at 52d9c784 confirmed green (Step 0.7
  passed; "failed command:" output is intentional negative-path
  test stderr, not a failure).

## Active bundle

- None.

## Active task — cycle 89: next autonomous chunk

Spec-runner-observable yield exhausted per cycle-88 survey (see
lesson). Remaining autonomous candidates are infrastructure
hardening:

1. **`check_uses_runtime_ptr.sh` extension** — lesson
   `2026-05-28-d180-detector-misses-bounds-fixups.md` names a
   hardening opportunity: extend regex to detect indirect R15
   use via `bounds_fixups.append` / `unreach_fixups.append`
   in per-op files. Closes the D-180 detector gap.
2. **`cleanup_orphans.sh` allowlist extension** — observed
   yesterday: `cljw repl | grep` pipeline orphan. Hook covers
   it; review for other dev-tool patterns that could orphan
   (wasmtime, node REPLs, etc.).
3. **handover.md archive prune** — top-level "## Larger §10
   work" + "Open questions / blockers" stable across many
   cycles; consider moving stable content to CLAUDE.md to keep
   handover ≤ 50 lines.

Cycle 89 picks (1) — concrete drift-detector hardening directly
named in a recent lesson; closes the named gap with a small
mechanical change.

## Larger §10 work (blocked / later)

- **10.E EH runtime** — gated on ADR-0120 Accept (exnref ValType).
- **10.M memory64 multi-memory** — autonomous substantially done.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-81; unchanged by cycle 82)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[multi-memory       ] return=407(pass=382 fail=25) trap=238(pass=237 fail=1)
                      invalid=2(pass=2) malformed=2(pass=2) skip=56
[wasm-3.0-assert    ] assert_return pass=790  assert_trap pass=449  assert_invalid pass=134 fail=0
```

## Open questions / blockers

- ADR-0120 — Status: Proposed; user Accept flip unblocks ~30 EH
  spec directives.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0112 (Tail Call), ADR-0114 (EH), ADR-0120 / 0123 (Proposed).
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- `.dev/lessons/2026-05-28-gate-tail-vs-exit-code.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
