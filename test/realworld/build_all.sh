#!/usr/bin/env bash
# build_all.sh — Build all real-world wasm test programs
#
# Usage: bash test/realworld/build_all.sh [--force]
#
# Requires: cargo (+ wasm32-wasip1 target), go, wasi-sdk ($WASI_SDK_PATH)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASM_DIR="$SCRIPT_DIR/wasm"
mkdir -p "$WASM_DIR"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
  esac
done

PASS=0
FAIL=0
SKIP=0
ERRORS=""

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  $1: $2"; }
log_skip() { echo "  SKIP: $1 — $2"; SKIP=$((SKIP + 1)); }

up_to_date() {
  local src="$1" out="$2"
  [ "$FORCE" = "1" ] && return 1
  [ ! -f "$out" ] && return 1
  [ "$src" -nt "$out" ] && return 1
  return 0
}

echo "=== Building C programs (wasi-sdk) ==="
if [ -n "${WASI_SDK_PATH:-}" ] && [ -f "$WASI_SDK_PATH/bin/clang" ]; then
  CC="$WASI_SDK_PATH/bin/clang"
  SYSROOT="$WASI_SDK_PATH/share/wasi-sysroot"
  for src in "$SCRIPT_DIR"/c/*.c; do
    name=$(basename "$src" .c)
    out="$WASM_DIR/c_${name}.wasm"
    if up_to_date "$src" "$out"; then
      log_skip "c_${name}" "up to date"
      continue
    fi
    if "$CC" --sysroot="$SYSROOT" -O2 -o "$out" "$src" -lm 2>/tmp/build_err_$$; then
      log_pass "c_${name}"
    else
      log_fail "c_${name}" "$(cat /tmp/build_err_$$)"
    fi
    rm -f /tmp/build_err_$$
  done
else
  log_skip "c_*" "WASI_SDK_PATH not set or clang not found"
fi

echo ""
echo "=== Building C++ programs (wasi-sdk) ==="
if [ -n "${WASI_SDK_PATH:-}" ] && [ -f "$WASI_SDK_PATH/bin/clang++" ]; then
  CXX="$WASI_SDK_PATH/bin/clang++"
  SYSROOT="$WASI_SDK_PATH/share/wasi-sysroot"
  for src in "$SCRIPT_DIR"/cpp/*.cpp; do
    name=$(basename "$src" .cpp)
    out="$WASM_DIR/cpp_${name}.wasm"
    if up_to_date "$src" "$out"; then
      log_skip "cpp_${name}" "up to date"
      continue
    fi
    if "$CXX" --sysroot="$SYSROOT" -O2 -fno-exceptions -o "$out" "$src" 2>/tmp/build_err_$$; then
      log_pass "cpp_${name}"
    else
      log_fail "cpp_${name}" "$(cat /tmp/build_err_$$)"
    fi
    rm -f /tmp/build_err_$$
  done
else
  log_skip "cpp_*" "WASI_SDK_PATH not set or clang++ not found"
fi

echo ""
echo "=== Building Go programs (wasip1/wasm) ==="
if command -v go &>/dev/null; then
  for dir in "$SCRIPT_DIR"/go/*/; do
    name=$(basename "$dir")
    out="$WASM_DIR/go_${name}.wasm"
    src="$dir/main.go"
    if up_to_date "$src" "$out"; then
      log_skip "go_${name}" "up to date"
      continue
    fi
    if (cd "$dir" && GOOS=wasip1 GOARCH=wasm go build -o "$out" .) 2>/tmp/build_err_$$; then
      log_pass "go_${name}"
    else
      log_fail "go_${name}" "$(cat /tmp/build_err_$$)"
    fi
    rm -f /tmp/build_err_$$
  done
else
  log_skip "go_*" "go not found"
fi

echo ""
echo "=== Building Rust programs (wasm32-wasip1) ==="
if command -v cargo &>/dev/null && rustup target list --installed 2>/dev/null | grep -q wasm32-wasip1; then
  for dir in "$SCRIPT_DIR"/rust/*/; do
    name=$(basename "$dir")
    out="$WASM_DIR/rust_${name}.wasm"
    cargo_toml="$dir/Cargo.toml"
    if up_to_date "$cargo_toml" "$out"; then
      log_skip "rust_${name}" "up to date"
      continue
    fi
    if cargo build --manifest-path "$cargo_toml" --target wasm32-wasip1 --release --quiet 2>/tmp/build_err_$$; then
      # Copy from target directory
      cp "$dir/target/wasm32-wasip1/release/${name}.wasm" "$out"
      log_pass "rust_${name}"
    else
      log_fail "rust_${name}" "$(cat /tmp/build_err_$$)"
    fi
    rm -f /tmp/build_err_$$
  done
else
  log_skip "rust_*" "cargo or wasm32-wasip1 target not found"
fi

echo ""
echo "=== Building TinyGo programs (wasip1) ==="
if command -v tinygo &>/dev/null; then
  for dir in "$SCRIPT_DIR"/tinygo/*/; do
    name=$(basename "$dir")
    out="$WASM_DIR/tinygo_${name}.wasm"
    src="$dir/main.go"
    if up_to_date "$src" "$out"; then
      log_skip "tinygo_${name}" "up to date"
      continue
    fi
    if (cd "$dir" && tinygo build -o "$out" -target=wasip1 -scheduler=none .) 2>/tmp/build_err_$$; then
      log_pass "tinygo_${name}"
    else
      log_fail "tinygo_${name}" "$(cat /tmp/build_err_$$)"
    fi
    rm -f /tmp/build_err_$$
  done
else
  log_skip "tinygo_*" "tinygo not found"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
if [ -n "$ERRORS" ]; then
  echo -e "Errors:$ERRORS"
fi
echo ""
echo "Wasm files in $WASM_DIR:"
ls -lh "$WASM_DIR"/*.wasm 2>/dev/null || echo "  (none)"

exit $FAIL
