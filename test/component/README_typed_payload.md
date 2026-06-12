# p17 ADR-0183 fixture: typed_payload (rich-typed invoke proof)

A real wit-bindgen (0.36) Rust component for the typed embedder API
(ADR-0183): world `typed-test` exports
`process: func(input: payload) -> result<payload, string>` where
`payload = record { xs: list<u32>, label: string }` (defined in an
interface and `use`d — so the type reaches the binary as an
imported-instance type declaration, exercising the named-type/nested-
scope resolution).

## Reproduce (Mac gen shell)

```sh
nix develop .#gen
mkdir /tmp/build && cd /tmp/build
cp <repo>/test/component/typed_payload.wit wit/world.wit
cp <repo>/test/component/typed_payload.rs src/lib.rs
# Cargo.toml: wit-bindgen = "0.36", crate-type = ["cdylib"], release strip
cargo build --target wasm32-wasip2 --release   # -> typed_payload.wasm (~51 KB)
```

Guest semantics: ok path appends `sum(xs)` to `xs` and `!` to `label`;
`label == "fail"` returns `err("boom: fail")`.
