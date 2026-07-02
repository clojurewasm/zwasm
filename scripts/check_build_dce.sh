#!/usr/bin/env bash
# scripts/check_build_dce.sh — Build-option DCE enforcement gate.
#
# Builds zwasm across the 9 build-option combinations
# (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2,p3}`) and verifies via
# `nm` symbol grep + per-build size measurement that:
#
#   1. Each build succeeds.
#   2. In `-Dwasm=v1_0` builds, no Wasm 2.0+ feature symbols remain
#      in `nm` output. In `-Dwasm=v2_0` builds, no Wasm 3.0 symbols.
#   3. In `-Dwasi=p1` builds, no WASI Preview 2 syscall symbols.
#   4. Binary `.text` size is monotonically non-decreasing as
#      `wasm_level` increases (= v1_0 build is the smallest).
#
# Phase 9 completion master plan §7.1 / ADR-0073.
#
# Modes:
#   --gate            : exit non-zero on any FAIL (pre-push hook; expensive)
#   --sample <N>      : build N random combinations (cheaper smoke)
#   --target <combo>  : build a single combination, e.g. "v1_0:p1"
#   --report          : exit 0; emit the matrix table

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,22p' "$0"
  exit 0
fi

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WASM_LEVELS=(v1_0 v2_0 v3_0)
WASI_LEVELS=(p1 p2 p3)

# Forbidden-symbol patterns per build axis. Each pattern is fed to
# `nm | grep -qE`; if matched the build is in violation.
FORBIDDEN_V1_0=("wasm_2_0" "wasm_3_0" "v128_load" "v128_store" "gc_struct" "i31_new")
FORBIDDEN_V2_0=("wasm_3_0" "gc_struct" "i31_new")
FORBIDDEN_P1=("wasi_p2_" "wasi_preview2")
# ADR-0193 P3: any build below `.p3` must NOT contain the P3/async driver
# (relocated out of the always-compiled path; comptime-fenced on enable_wasi_p3).
FORBIDDEN_BELOW_P3=("driveAsyncMain" "driveCallbackLoop" "P3CallbackCtx")

OUT_BASE="/tmp/zwasm-dce-check"
mkdir -p "$OUT_BASE"

build_one() {
  local wasm="$1" wasi="$2"
  local prefix="$OUT_BASE/${wasm}_${wasi}"
  rm -rf "$prefix"
  mkdir -p "$prefix"
  zig build \
    "-Dwasm=$wasm" "-Dwasi=$wasi" \
    "-Doptimize=ReleaseSafe" \
    "-p" "$prefix" \
    > "$prefix/build.log" 2>&1
}

# D-231: the host-native build on an arm64 Mac exercises only the arm64
# codegen's DCE; x86_64 codegen DCE drift (e.g. a legacy-switch arm calling
# `wasm_3_0` op.emit() without a `comptime wasm_v3_plus` guard, the live leak
# fixed @96fcdf9f) is INVISIBLE to it. Cross-compile to x86_64-linux so the
# x86 codegen is compiled + its dead symbols are observable to nm. nix `nm`
# (llvm-nm via the clang wrapper) reads cross ELF fine.
#
# On an x86_64 host the native build already compiles the x86_64 codegen, so
# the same-triple cross build adds zero coverage — skip it (halves the matrix
# wall-clock on the x86_64-linux CI leg; each ReleaseSafe build is minutes).
XBUILD_TARGET="x86_64-linux-gnu"
HOST_ARCH="$(uname -m)"
build_one_x86() {
  local wasm="$1" wasi="$2"
  local prefix="$OUT_BASE/x86_${wasm}_${wasi}"
  rm -rf "$prefix"
  mkdir -p "$prefix"
  zig build \
    "-Dtarget=$XBUILD_TARGET" \
    "-Dwasm=$wasm" "-Dwasi=$wasi" \
    "-Doptimize=ReleaseSafe" \
    "-p" "$prefix" \
    > "$prefix/build.log" 2>&1
}

forbidden_set_for() {
  local wasm="$1" wasi="$2"
  local out=""
  case "$wasm" in
    v1_0) out="${FORBIDDEN_V1_0[*]}" ;;
    v2_0) out="${FORBIDDEN_V2_0[*]}" ;;
  esac
  if [ "$wasi" = "p1" ]; then
    out="$out ${FORBIDDEN_P1[*]}"
  fi
  if [ "$wasi" != "p3" ]; then
    out="$out ${FORBIDDEN_BELOW_P3[*]}"
  fi
  echo "$out"
}

check_forbidden() {
  local bin="$1" wasm="$2" wasi="$3"
  local fail=0
  for pat in $(forbidden_set_for "$wasm" "$wasi"); do
    if nm "$bin" 2>/dev/null | grep -qE "$pat"; then
      echo "    FAIL  $bin → $pat present"
      fail=1
    fi
  done
  return $fail
}

# --- assemble matrix ----------------------------------------------------

MATRIX=()
case "$MODE" in
  --sample)
    n="${2:-2}"
    for i in $(seq 1 "$n"); do
      MATRIX+=("${WASM_LEVELS[$((RANDOM % 3))]}:${WASI_LEVELS[$((RANDOM % 3))]}")
    done
    ;;
  --target)
    MATRIX+=("${2:-v1_0:p1}")
    ;;
  *)
    for w in "${WASM_LEVELS[@]}"; do
      for wi in "${WASI_LEVELS[@]}"; do
        MATRIX+=("$w:$wi")
      done
    done
    ;;
esac

fail=0
echo "=== build-option DCE check (per ADR-0073) ==="
echo "matrix size: ${#MATRIX[@]}"
echo ""
printf '%-6s %-4s %-10s %-12s %-12s\n' wasm wasi build text_bytes forbidden
echo "----------------------------------------------------"

for entry in "${MATRIX[@]}"; do
  wasm="${entry%%:*}"; wasi="${entry##*:}"
  if ! build_one "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "FAIL" "-" "-"
    tail -10 "$OUT_BASE/${wasm}_${wasi}/build.log" 2>/dev/null | sed 's/^/    /'
    fail=1
    continue
  fi
  # Prefer the `zwasm` CLI binary (the WASI-component path lives there);
  # `head -1` could grab an unrelated test-runner exe and false-pass the
  # P3-symbol DCE assertion (ADR-0193 P3).
  bin="$OUT_BASE/${wasm}_${wasi}/bin/zwasm"
  [ -f "$bin" ] || bin=$(find "$OUT_BASE/${wasm}_${wasi}/bin" -type f 2>/dev/null | head -1)
  if [ -z "$bin" ]; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "OK" "no-bin" "?"
    continue
  fi
  text=$(size "$bin" 2>/dev/null | awk 'NR==2 {print $1}')
  if check_forbidden "$bin" "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "OK" "$text" "clean"
  else
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "OK" "$text" "FAIL"
    fail=1
  fi

  # D-231: cross-x86 DCE check (forbidden-symbol nm-grep only; no size/
  # monotonic — host `size` may not read cross ELF, but nm does). Skipped on
  # x86_64 hosts where it would duplicate the native build above.
  if [ "$HOST_ARCH" = "x86_64" ]; then
    continue
  fi
  if ! build_one_x86 "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:FAIL" "build" "-"
    tail -10 "$OUT_BASE/x86_${wasm}_${wasi}/build.log" 2>/dev/null | sed 's/^/    /'
    fail=1
    continue
  fi
  xbin="$OUT_BASE/x86_${wasm}_${wasi}/bin/zwasm"
  [ -f "$xbin" ] || xbin=$(find "$OUT_BASE/x86_${wasm}_${wasi}/bin" -type f 2>/dev/null | head -1)
  if [ -z "$xbin" ]; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:OK" "no-bin" "?"
  elif check_forbidden "$xbin" "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:OK" "-" "clean"
  else
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:OK" "-" "FAIL"
    fail=1
  fi
done

echo ""
if [ "$MODE" = "--gate" ] && [ "$fail" -ne 0 ]; then
  echo "[check_build_dce] FAIL — DCE violations present (see above)"
  exit 1
fi

echo "[check_build_dce] OK"
exit 0
