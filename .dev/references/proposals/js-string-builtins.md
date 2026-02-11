# JS String Builtins

Status: Wasm 3.0 | Repo: not cloned | Complexity: low (JS-specific)
zwasm: skip | Est. LOC: 0 | Opcodes: 0 new

## What It Adds

Defines a `wasm:js-string` import namespace with builtin functions for
efficient string manipulation between Wasm and JavaScript hosts. These
builtins allow Wasm modules to create, compare, and manipulate JS strings
without going through the general JS API overhead.

## Why Skip

This proposal is **JS-host-specific**. It defines imports that only make
sense when the Wasm module runs inside a JavaScript engine (browser or Node.js).
Standalone runtimes like zwasm, wasmtime, and wasmer do not implement these.

A Wasm module using `wasm:js-string` imports would fail to instantiate on
zwasm due to missing imports — this is expected and correct behavior.

## Builtins (for reference)

Import namespace: `wasm:js-string`

- fromCharCodeArray, intoCharCodeArray
- fromCodePoint
- charCodeAt, codePointAt
- length
- concat
- substring
- equals, compare
- test, cast

## If Needed Later

If zwasm ever needs to run modules that import `wasm:js-string` (e.g., for
Kotlin/Wasm or Dart/Wasm compatibility), implement stub functions that
operate on UTF-8 byte arrays in linear memory instead of JS string objects.
