#!/usr/bin/env bash
# Regenerate the WASI 0.3 (wasm32-wasip3) conformance fixtures (Mac host only).
#
# wasip3 is a Tier-3 rust target (no prebuilt std / wasi-libc) + the nix nightly
# rust-lld is broken on Darwin, so the build uses the recipe baked into
# flake.nix `devShells.gen-wasip3` ($ZWASM_WASIP3_RUSTFLAGS): nightly -Z build-std
# + nixpkgs wasm-ld + the stable toolchain's wasip2 wasi-libc. Full rationale:
# lesson 2026-06-16-wasip3-hermetic-build-recipe + D-448.
#
# Run INSIDE the gen-wasip3 shell:
#   nix develop .#gen-wasip3 --command bash scripts/gen_wasip3_fixtures.sh
#
# The emitted `.wasm` is committed; the test hosts run it via the edge-runner.
set -euo pipefail

if [ -z "${ZWASM_WASIP3_RUSTFLAGS:-}" ]; then
  echo "error: \$ZWASM_WASIP3_RUSTFLAGS unset — run inside 'nix develop .#gen-wasip3'" >&2
  exit 1
fi

cd "$(dirname "$0")/../test/component/wasip3"

RUSTFLAGS="$ZWASM_WASIP3_RUSTFLAGS" \
  cargo build -Z build-std=std,panic_abort --target wasm32-wasip3 --release

# Each [[bin]] in Cargo.toml → a committed top-level <name>.wasm fixture.
for bin in cli-exit cli-stdout cli-stderr cli-env cli-args cli-stdin cli-clocks; do
  src="target/wasm32-wasip3/release/${bin}.wasm"
  wasm-tools validate "$src"
  cp "$src" "${bin}.wasm"
  echo "generated ${bin}.wasm ($(wc -c < "${bin}.wasm") bytes)"
done
