#!/usr/bin/env bash
# Native-engine differential sweep (ADR-0192 Phase I → real gap list).
#
# The C-API sweep (scripts/wasmtime_misc_sweep.sh) can't instantiate GC /
# typed-ref modules — the C-API is the MVP wasm.h surface. This sweep bakes
# the proposal buckets of wasmtime's tests/misc_testsuite/ into the NATIVE
# spec-runner manifest format and runs them through the GC/typed-ref-capable
# `zwasm-spec-wasm-3-0-assert` runner. Residual FAILs here are real core gaps.
#
# Buckets the native Wasm-3.0 runner enumerates (PROPOSALS):
#   gc · memory64 · tail-call · function-references · multi-memory
# (simd → simd_assert_runner; threads/custom-page-sizes have no native
#  Wasm-3.0 runner subdir — handled separately / documented out-of-scope.)
#
# Usage:
#   bash scripts/wasmtime_misc_native_sweep.sh [bucket ...]   # default: all 5
#
# Output: /tmp/wmt-native/<bucket>.txt (runner stdout per bucket) +
#         /tmp/wmt-native/summary.txt (per-bucket passed/failed tally).
set -uo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASMTIME_REPO:-$HOME/Documents/OSS/wasmtime}
MISC="$UPSTREAM/tests/misc_testsuite"
RUNNER=zig-out/bin/zwasm-spec-wasm-3-0-assert
DISTIL=scripts/spec_distill/wast_to_native_manifest.py
OUT=/tmp/wmt-native
DEFAULT_BUCKETS=(gc memory64 tail-call function-references multi-memory)

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not in PATH (nix develop .#gen)"; exit 1; }
[ -d "$MISC" ] || { echo "misc_testsuite not found at $MISC"; exit 1; }

echo "[native-sweep] building runner..."
zig build install >/dev/null 2>&1 || { echo "zig build failed"; exit 1; }
[ -x "$RUNNER" ] || { echo "runner not at $RUNNER after build"; exit 1; }

if [ "$#" -gt 0 ]; then BUCKETS=("$@"); else BUCKETS=("${DEFAULT_BUCKETS[@]}"); fi

rm -rf "$OUT"; mkdir -p "$OUT"
CORPUS="$OUT/corpus"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

bake_one() {
  local bucket="$1" wast="$2"
  local name; name=$(basename "$wast" .wast)
  local out_dir="$CORPUS/$bucket/$name"
  local tmp; tmp=$(mktemp -d)
  if ! ( cd "$tmp" && wasm-tools json-from-wast "$wast" -o c.json --wasm-dir . >/dev/null 2>&1 ); then
    echo "  CONVFAIL $bucket/$name" >> "$SUMMARY"; rm -rf "$tmp"; return
  fi
  mkdir -p "$out_dir"
  python3 "$DISTIL" "$tmp/c.json" "$out_dir/manifest.txt" 2>/dev/null || { rm -rf "$out_dir" "$tmp"; return; }
  # Materialize referenced .wasm (module/assert_* lines), strip name section.
  while read -r d1 a2 a3 _; do
    local file=""
    case "$d1" in
      module) [ "${a2:0:1}" = '$' ] && file="$a3" || file="$a2" ;;
      assert_invalid|assert_malformed|assert_uninstantiable|assert_unlinkable) file="$a2" ;;
    esac
    [ -n "$file" ] || continue
    if [ -f "$tmp/$file" ]; then
      wasm-tools strip --all "$tmp/$file" -o "$out_dir/$file" 2>/dev/null || cp "$tmp/$file" "$out_dir/$file"
    elif [ -f "$tmp/${file%.wasm}.wat" ]; then
      wasm-tools parse "$tmp/${file%.wasm}.wat" -o "$out_dir/$file" 2>/dev/null || true
    fi
  done < "$out_dir/manifest.txt"
  rm -rf "$tmp"
}

for bucket in "${BUCKETS[@]}"; do
  src_dir="$MISC/$bucket"
  [ -d "$src_dir" ] || { echo "[native-sweep] no bucket $bucket"; continue; }
  n=0
  while IFS= read -r wast; do bake_one "$bucket" "$wast"; n=$((n+1)); done < <(find "$src_dir" -name '*.wast' | sort)
  echo "[native-sweep] baked $bucket: $n .wast"
done

echo "[native-sweep] running native runner over baked corpus..."
# The runner enumerates PROPOSALS subdirs under the corpus root.
timeout 600 "$RUNNER" "$CORPUS" --fail-detail > "$OUT/run.txt" 2>&1 || true
echo "=== per-bucket tally ===" >> "$SUMMARY"
grep -E "^\[.*\].*passed.*failed|^\[.*\] \(no subdir" "$OUT/run.txt" >> "$SUMMARY" 2>/dev/null || true
echo "[native-sweep] done -> $OUT/run.txt + $SUMMARY"
tail -30 "$OUT/run.txt"
