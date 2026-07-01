# `test/spec/` — vendored WebAssembly conformance corpora

The `.wast` / `.wat` conformance corpora under this directory (and their
derived manifests) are **vendored from upstream WebAssembly projects**, not
authored by zwasm:

- **[WebAssembly/testsuite](https://github.com/WebAssembly/testsuite)** and
  the per-proposal test suites in
  **[WebAssembly/spec](https://github.com/WebAssembly/spec)** — the core and
  Wasm 3.0 proposal `.wast` assertions.

Pinned upstream revisions (see [`.dev/spec_pin.yaml`](../../.dev/spec_pin.yaml)):

| Upstream                 | Commit      | Baseline    |
|--------------------------|-------------|-------------|
| `WebAssembly/testsuite`  | `0dc0343c`  | 2026-06-14  |
| `WebAssembly/spec`       | `f3d34482`  | 2026-06-14  |

The regeneration scripts are `scripts/regen_spec_*.sh`; `scripts/check_spec_bump.sh`
alerts when upstream advances beyond the pinned revisions.

## License

The vendored WebAssembly test suites are licensed under **Apache License 2.0**
by the WebAssembly Community Group. zwasm is itself Apache-2.0, so the full
license text in the repository root [`LICENSE`](../../LICENSE) applies to this
vendored material as well. See [`THIRD_PARTY.md`](../../legal/THIRD_PARTY.md) for the
complete third-party attribution list.

zwasm-authored fixtures in this tree (e.g. the `component-model-assert/*`
manifests and `smoke/` cases) are covered by the repository's own Apache-2.0
license.
