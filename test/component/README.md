# p17 Component Model fixture: greet (string -> string)

Minimal real WebAssembly component exercising `canon lift` of an export
with the canonical ABI string return (cabi_realloc + memory + post-return).

## Reproduce

```sh
wasm-tools parse greet_core.wat -o greet_core.wasm
wasm-tools component embed greet.wit greet_core.wasm -o greet_embedded.wasm
wasm-tools component new greet_embedded.wasm -o greet_component.wasm
wasm-tools validate --features component-model greet_component.wasm
```

(`greet_embedded.wasm` is a transient intermediate; not committed.)

## Files

- `greet.wit`            — WIT world: `export greet: func(name: string) -> string;`
- `greet_core.wat`       — hand-written core module (canonical core ABI)
- `greet_core.wasm`      — assembled core module (498 B)
- `greet_component.wasm` — final component (831 B); THE fixture

## Behaviour

`greet(name)` returns `"Hello, " ++ name ++ "!"`. Bump allocator backs
`cabi_realloc`; return area is at memory offset 0 (`[out_ptr, out_len]`).
