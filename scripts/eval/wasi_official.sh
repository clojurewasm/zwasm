#!/usr/bin/env bash
# scripts/eval/wasi_official.sh — run the OFFICIAL WebAssembly/wasi-testsuite
# against zwasm, with a wasmtime control run through the identical harness.
#
# Backs §1.7 (WASI 0.1) and §1.9 (WASI 0.3) of
# `.dev/meta_audits/2026-08-14-product-evaluation.md`.
#
# The control matters: a failure list is only evidence of a zwasm gap if a
# known-good runtime passes the same tests through the same adapter plumbing.
#
# Setup:
#   git clone -b prod/testsuite-base \
#     https://github.com/WebAssembly/wasi-testsuite ~/Documents/OSS/wasi-testsuite
#
# Usage:
#   WASI_TESTSUITE=/path/to/wasi-testsuite bash scripts/eval/wasi_official.sh [outdir]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="${WASI_TESTSUITE:-$HOME/Documents/OSS/wasi-testsuite}"
OUT="${1:-$ROOT/private/eval/wasi}"

[ -d "$SUITE/test-runner" ] || { echo "wasi-testsuite not found at $SUITE" >&2; exit 1; }
mkdir -p "$OUT"
cp "$ROOT/scripts/eval/wasi_adapter_zwasm.py" "$SUITE/adapters/zwasm.py"

P1_DIRS=(
  "tests/rust/testsuite/wasm32-wasip1"
  "tests/c/testsuite/wasm32-wasip1"
  "tests/assemblyscript/testsuite/wasm32-wasip1"
)

cd "$SUITE"

echo "=== WASI 0.1 — zwasm ==="
ZWASM="${ZWASM:-$ROOT/zig-out/bin/zwasm}" \
  python3 test-runner/wasi_test_runner.py -t "${P1_DIRS[@]}" \
    -r adapters/zwasm.py --disable-colors \
    --json-output-location "$OUT/p1_zwasm.json" | tail -3

if command -v wasmtime >/dev/null; then
  echo "=== WASI 0.1 — wasmtime control ==="
  python3 test-runner/wasi_test_runner.py -t "${P1_DIRS[@]}" \
    -r adapters/wasmtime.py --disable-colors \
    --json-output-location "$OUT/p1_wasmtime.json" | tail -3
fi

# WASI 0.3 needs a `-Dwasi=p3` build. As of 2.5.0 the CLI path HANGS on
# cli-stdout-flush under this harness (report §1.10) — zwasm's own 45/45 is
# measured in-process via `zig build test-wasi-p3 -Dtest-filter=wasip3-official`,
# not through the CLI. Kept here (opt-in) so the CLI gap stays measurable.
if [ -n "${ZWASM_P3:-}" ]; then
  echo "=== WASI 0.3 — zwasm CLI (expect hangs; bounded) ==="
  ZWASM="$ZWASM_P3" ZWASM_WASI_VERSIONS=wasm32-wasip3 \
    timeout 900 python3 test-runner/wasi_test_runner.py \
      -t tests/rust/testsuite/wasm32-wasip3 -r adapters/zwasm.py --disable-colors \
      --json-output-location "$OUT/p3_zwasm_cli.json" | tail -3
fi

if command -v wasmtime >/dev/null; then
  echo "=== WASI 0.3 — wasmtime control (full 52-test upstream corpus) ==="
  python3 test-runner/wasi_test_runner.py -t tests/rust/testsuite/wasm32-wasip3 \
    -r adapters/wasmtime.py --disable-colors \
    --json-output-location "$OUT/p3_wasmtime.json" | tail -3
fi

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
for f in sorted(os.listdir(out)):
    if not f.endswith(".json"):
        continue
    d = json.load(open(os.path.join(out, f)))
    tot = fails = 0
    names = []
    for s in d["results"]:
        tot += s["passed"] + s["failed"] + s["skipped"]
        fails += s["failed"]
        names += [t["name"] for t in s["tests"] if t["outcome"] != "pass"]
    print(f"\n{f}: {tot - fails}/{tot} pass")
    for n in names:
        print(f"    FAIL {n}")
PY
