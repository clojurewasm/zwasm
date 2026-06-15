# Building wasm32-wasip3 (WASI 0.3) components hermetically on a nix/Darwin Mac

**Date**: 2026-06-16
**Context**: Front ① (WASI 0.3 conformance), path ② (plain rust wasip3, no
wit-bindgen). Spike `private/spikes/wasip3-build-std`. Baked into
`flake.nix devShells.gen-wasip3` + `$ZWASM_WASIP3_RUSTFLAGS`.

**Problem**: wasm32-wasip3 is a Tier-3 rust target (added ~2026, WASI 0.3
ratified 2026-06-11). Tier 3 means: (a) NO prebuilt rust-std component, (b) NO
prebuilt wasi-libc self-contained objects. Plus the nix rust-overlay nightly
`rust-lld` is broken on Darwin (`dyld: @rpath/libLLVM.dylib` then, once pointed
at any nix libLLVM, `Symbol not found __ZTVN4llvm3lto5DTLTOE` — neither nixpkgs
llvm-21 nor rust's `-source` libLLVM matches the prebuilt rust-lld). So the
obvious paths (add target to flake `targets=[...]`; use bundled rust-lld) both
fail.

**The recipe that works** (verified: zwasm runs the output → exit code 1, the
wasi-testsuite cli-exit expectation):
1. **std**: nightly + `rust-src` extension + `cargo build -Z
   build-std=std,panic_abort` — builds std (and the `wasip3` crate) from source.
   No libc `[patch]` needed as of nightly-2026-06-14 (the 2025-10 blocker is gone).
2. **linker**: `wasm-component-ld` (the rust-bundled component-wrapping linker)
   accepts `--wasm-ld-path <PATH>` — point it at **nixpkgs `lld`'s `wasm-ld`**
   (a clean static binary), bypassing the broken bundled rust-lld entirely.
3. **wasi-libc**: pass `-Clink-self-contained=no` + the **STABLE** toolchain's
   wasip2 `crt1-command.o` + `-L<dir>` + `-lc` (wasip3's libc layer == wasip2's,
   per rustc docs). The stable `.#gen` rust ships wasip2 self-contained; the
   nightly does not ship wasip3's.

All three are nix-pinned (`genPkgs.lld`, the stable `rustWasm`, pinned nightly
`2026-06-14`) → fully hermetic + reproducible (same 70372-byte component).

**How to apply**: `nix develop .#gen-wasip3`, then `RUSTFLAGS=$ZWASM_WASIP3_RUSTFLAGS
cargo build -Z build-std=std,panic_abort --target wasm32-wasip3 --release`.
**Caveats** (D-448 note): the pinned nightly needs periodic refresh; the
wasip2-libc-borrow assumes the wasip3 libc ABI stays == wasip2's (re-verify on a
wasip3 std bump); a wasip3 component still imports some `wasi:cli/*@0.2.x`
interfaces (the documented transitional phase — zwasm's P2 host satisfies them).
The OFFICIAL wasi-testsuite (Buck2 + wit-bindgen-async + wkg) is NOT used — path
② (plain rust) is lighter and proves the same behaviors.
