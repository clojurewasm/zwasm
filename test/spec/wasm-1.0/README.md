# `test/spec/wasm-1.0/` — Wasm Core 1.0 (MVP) curated corpus

Hand-curated Wasm-1.0-pure subset of the upstream
`WebAssembly/spec/test/core/` testsuite, baked via
`wast2json`. Per ADR-0002 (`.dev/decisions/0002_phase1_mvp_corpus_curation.md`)
this corpus is the §9.1 / 1.9 fail=0 / skip=0 gate's input.

**Upstream commit pinned**: `d7b678327cd370cdbc5acfa94bd108772e2bef68`
(`~/Documents/OSS/WebAssembly/spec/`). When upstream advances, the
regen path needs the pin updated and the curation list re-verified.

## Inclusion list

The first module (`<name>.0.wasm`) of each `.wast` file:

- `const.wast`         — const-folding tests
- `forward.wast`       — forward function references
- `labels.wast`        — `block` / `loop` labels and br
- `local_get.wast`     — local read patterns
- `local_set.wast`     — local write patterns
- `nop.wast`           — `nop` placement; uses `call`, `call_indirect`,
  `select`, `global.get` / `global.set`, `br_table`, `memory.grow`
- `switch.wast`        — large `br_table`-based switch
- `unreachable.wast`   — polymorphic-stack rule exercises
- `unwind.wast`        — control-flow unwinding via `br`

## Regenerating

```bash
bash scripts/regen_test_data.sh
```

The script invokes `wast2json` (from `wabt`, in the dev shell)
against each upstream `.wast` listed above and copies the
resulting `.0.wasm` here. Other generated files (`.1.wasm`, `.2.wasm`,
… and `.json` metadata) are intentionally **not** committed —
those frequently embed `(assert_invalid …)` modules whose
expected-failure semantics need wast-directive parsing in the
runner (deferred to Phase 2 with the interpreter, per ADR-0002).

## What the runner does

`zig build test-spec` walks both `test/spec/smoke/` and this
directory. For each `.wasm`:

1. Parser decodes magic + version + section iterator.
2. Type / function / code / global / import section bodies are
   decoded.
3. Per defined function, the validator runs over the body
   (operand stack + control stack + polymorphic-stack rule).

If any stage errors out, the runner prints `FAIL` and exits 1.
fail=0 / skip=0 across Mac aarch64 + OrbStack Ubuntu x86_64 +
windowsmini SSH is the §9.1 / 1.9 release gate.
