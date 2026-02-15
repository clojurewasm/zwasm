#!/bin/bash
# Build thread test wasm modules using Rust wasm32-wasip1-threads target.
# Prerequisites: rustup target add wasm32-wasip1-threads
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building rust-atomic..."
(cd "$SCRIPT_DIR/rust-atomic" && cargo build --target wasm32-wasip1-threads --release --quiet)
echo "  -> $(ls -lh "$SCRIPT_DIR/rust-atomic/target/wasm32-wasip1-threads/release/atomic-test.wasm" | awk '{print $5}')"

echo "All thread test modules built."
echo "Run: zwasm run test/threads/rust-atomic/target/wasm32-wasip1-threads/release/atomic-test.wasm"
