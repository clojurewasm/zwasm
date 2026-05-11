# Skip — Wasm text-format (`.wat`) parser intentionally not implemented

- **Status**: Accepted (skip permanently — outside zwasm v2 scope)
- **Date**: 2026-05-07
- **Author**: zwasm v2 / continue loop
- **Tags**: phase-7, skip-adr, spec-assert, text-format, scope
- **Fixtures covered**: 20 `directive-assert_malformed-text`
  entries in `test/spec/wasm-1.0-assert/int_literals/manifest.txt`
  (and any future `.wast` fixtures whose `assert_malformed`
  command has `module_type == "text"`).

## What v2 does today

`spec_assert_runner` reads each manifest line. For
`assert_malformed` directives whose underlying wast2json command
has `module_type == "text"`, the regen emits
`skip directive-assert_malformed-text` and the runner counts the
line as skipped. There is no path that exercises the malformed
text — zwasm has no text-format parser to feed it through.

## Why v2 declines

zwasm v2 is **binary-format only** by design. The Wasm text
format is upstream's source-level syntax for tooling (wabt,
wasm-tools, browsers' `WebAssembly.compile()` from a string).
Production guests ship as `.wasm` binaries from compilers
(Rust, C/C++, TinyGo, Zig); a runtime that consumes the binary
format is sufficient for every realworld scenario in the project
charter (`~/zwasm/private/v2-investigation/CONCLUSION.md`).

ROADMAP §A2 ("file-size hard cap") + §P3 ("cold-start under
ms"): the text parser would add a substantial decoder layer
(arity ≈ 4–6 KLOC in upstream wabt) that runs only at the
toolchain boundary, never at runtime. Pulling it in would dilute
the runtime's surface and cold-start budget for zero production
value.

## What an `assert_malformed text` upstream test exercises

Upstream `(assert_malformed (module $name quote "..."))` tests
the **WAT lexer / parser** rejecting malformed source-level
syntax (e.g. trailing garbage in integer literals, illegal
escape sequences). These are tooling-vendor concerns; runtimes
delegate them to whichever toolchain produced the binary.

## What v2 needs to fix this honestly

Nothing. The skip is permanent: `module_type == "text"` cases
will continue to surface as `skip directive-assert_malformed-text`
forever. Per ADR-0029 they count as `skip-adr-<this-ADR>`, not
`skip-impl`, so the §9.7 / 7.5 row's `skip-impl == 0` exit
criterion is unaffected by them.

If a future Wasm proposal moves text-only test fixtures into
binary form (e.g. wasm-tools regenerates them as
`(assert_malformed (module binary "..."))`), regen will pick
them up automatically as `assert_malformed <filename>` and the
runner exercises them via the existing parser path.

## Removal plan

This ADR is permanent. The fixture-tally line in the runner's
output (`SKIP-ADR  ... directive-assert_malformed-text`) cites
this ADR by basename so reviewers can trace the deliberate
rejection.

## Implementation (per ADR-0029 Path B, since chunk 9.9-h-22)

Manifest lines waived under this ADR carry the prefix
`skip-adr-skip_text_format_parser <reason>`. Emitted by
`scripts/regen_spec_1_0_assert.sh` + `scripts/regen_spec_simd_assert.sh`
when the upstream `assert_malformed` directive has
`module_type == "text"`. Parsed by `spec_assert_runner.zig` +
`simd_assert_runner.zig` (since chunk 9.9-h-21); the runner emits
the line in the `skip-adr` tally rather than `skip-impl`, so the
`skip-impl == 0` gate is preserved while these waivers are
visible.

## References

- ADR-0029 (skip-impl vs skip-adr counting)
- `.claude/rules/no_workaround.md` (paired-ADR discipline for
  any `SKIP-X-Y` pattern)
- `scripts/regen_spec_1_0_assert.sh` § elif `assert_malformed`
- `test/spec/spec_assert_runner.zig` (will be extended to mark
  the line as `SKIP-ADR-text-format-parser` for visibility)
