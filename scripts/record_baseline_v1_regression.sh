#!/usr/bin/env bash
# Regenerate `bench/baseline_v1_regression.yaml` — the Phase-6 /
# §9.6 / 6.4 interp wall-clock floor.
#
# The baseline is per-host: re-running on a different machine
# overwrites the file. Phase-7+ JIT comparisons read the most-
# recent record; the file is intentionally NOT append-only (unlike
# `bench/history.yaml`) since the baseline is "this host, this
# commit, current interp" — the comparison is against the LATEST
# baseline, not historical drift.

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "[record_baseline] hyperfine not in PATH (need it from flake.nix dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[record_baseline] python3 not in PATH" >&2
  exit 1
fi

zig build

# Curated subset: 5 fixtures whose runWasm produces a stable u8
# exit reproducibly. These are within the §9.6 / 6.1 chunk b
# 39-PASS bucket. Add fixtures here ONLY when they show stddev
# under ~3 ms over 5 runs — noisy entries muddy the Phase-7
# comparison.
FIXTURES=(
  c_integer_overflow
  c_many_functions
  c_control_flow
  rust_compression
  rust_enum_match
)

CMDS=()
for f in "${FIXTURES[@]}"; do
  CMDS+=("./zig-out/bin/zwasm run test/realworld/wasm/${f}.wasm")
done

TMP=$(mktemp -t baseline.XXXXXX.json)
trap "rm -f '$TMP'" EXIT

hyperfine --ignore-failure --warmup 2 --runs 5 --export-json "$TMP" "${CMDS[@]}" >&2

SHA=$(git rev-parse HEAD)
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
case "$(uname -sm)" in
  "Darwin arm64") ARCH="aarch64-darwin" ;;
  "Linux x86_64") ARCH="x86_64-linux" ;;
  *) ARCH="$(uname -sm | tr ' ' '-')" ;;
esac

python3 - "$TMP" > bench/baseline_v1_regression.yaml <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print("# bench/baseline_v1_regression.yaml")
print("#")
print("# Per-fixture interp wall-clock baseline recorded for the")
print("# Phase-6 / §9.6 / 6.4 deliverable. Phase-7+ JIT runs compare")
print("# against this floor; A13 holds the regression suite green")
print("# from this point forward.")
print("#")
print("# Subset rationale: 5 of the 39 PASS-bucket realworld fixtures")
print("# the ones that runWasm carries to a stable u8 exit code")
print("# reproducibly. 35+ fixtures excluded as needs-Phase-6-follow-up")
print("# execution-coverage work (10 SKIP-VALIDATOR + 39 trap-mid-")
print("# execution; the 5 picked here are within the 39-trap subset")
print("# but produce stable wall-clock numbers because the trap site")
print("# is reproducible). Spread (stddev) and repeatability under")
print("# noise are what matter, not absolute speed (per ROADMAP §9.6")
print("# / 6.4 row text).")
print("#")
print("# Regen: bash scripts/record_baseline_v1_regression.sh")
print()
print("- date: __DATE__")
print("  commit: __SHA__")
print("  arch: __ARCH__")
print('  reason: "Initial Phase-6 / 6.4 interp wall-clock baseline"')
print("  runs: 5")
print("  warmup: 2")
print("  benches:")
for r in data["results"]:
    name = r["command"].split("/")[-1].replace(".wasm", "")
    print(f"    - name: {name}")
    print(f"      mean_ms: {r['mean']*1000:.2f}")
    print(f"      stddev_ms: {r['stddev']*1000:.2f}")
    print(f"      min_ms: {r['min']*1000:.2f}")
    print(f"      max_ms: {r['max']*1000:.2f}")
PY

sed -i.bak \
  -e "s|__DATE__|$DATE|" \
  -e "s|__SHA__|$SHA|" \
  -e "s|__ARCH__|$ARCH|" \
  bench/baseline_v1_regression.yaml
rm bench/baseline_v1_regression.yaml.bak

echo "[record_baseline] wrote bench/baseline_v1_regression.yaml ($(wc -l < bench/baseline_v1_regression.yaml) lines)"
