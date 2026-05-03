#!/usr/bin/env bash
# Regenerate the curated v1 carry-over corpus from the v1
# reference clone's `test/e2e/wast/` bundle.
#
# Per ROADMAP §9.6 / 6.0: zwasm v2 inherits the regression
# coverage v1 accumulated outside the upstream spec testsuite —
# fuzz-found bugs, edge cases reported against wasmtime, and
# embenchen-style integration patterns. The script bakes each
# named `.wast` into the same flat manifest format `wast_runner`
# already consumes for the §9.2 / 2.7 corpus, so the runner is
# unchanged.
#
# Adding a NAMES entry is a positive opt-in: each one must
# successfully `wast2json` AND every emitted module must pass
# `zig build test-v1-carry-over`. If `test-v1-carry-over` fails
# after re-running this script, the new entry surfaced a v2
# validator gap — open a follow-up §9.6 task rather than
# silently drop the entry.

set -euo pipefail
cd "$(dirname "$0")/.."

V1_REPO=${ZWASM_V1_REPO:-$HOME/Documents/MyProducts/zwasm}
DEST=test/v1_carry_over

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_v1_carry_over] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_v1_carry_over] python3 not found" >&2
  exit 1
fi
if [ ! -d "$V1_REPO/test/e2e/wast" ]; then
  echo "[regen_v1_carry_over] v1 tree not found at $V1_REPO/test/e2e/wast" >&2
  echo "[regen_v1_carry_over] set ZWASM_V1_REPO env var to override" >&2
  exit 1
fi

# Curated initial set — Wasm 1.0 / 2.0 features only. GC / EH /
# threads / SIMD / multi-memory carry-overs come post-Phase-6 as
# their respective phases enable the underlying ops.
NAMES=(
  empty                # zero-instruction body + drop edge cases
  add                  # i32.add wraparound regression
  div-rem              # signed div / rem trap matrix
  f64-copysign         # f64.copysign sign-of-zero / NaN propagation
)

# Known-blocked carry-overs (do NOT add to NAMES until the
# referenced §9.6 follow-up lands):
#   br-table-fuzzbug   — multi-param `loop` block; needs the
#                        multivalue (multi-param) BlockType
#                        carry-over already queued in handover
#                        (Phase 2 chunk 3b carry-over absorbed
#                        into Phase 6 per ADR-0008).

for n in "${NAMES[@]}"; do
  src="$V1_REPO/test/e2e/wast/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_v1_carry_over] missing $src" >&2
    exit 1
  fi
  TMP=$(mktemp -d)
  trap "rm -rf '$TMP'" EXIT

  ( cd "$TMP" && wast2json \
      --enable-function-references \
      --enable-tail-call \
      --enable-extended-const \
      --enable-multi-memory \
      "$src" -o "$n.json" >/dev/null 2>&1 )

  out_dir="$DEST/$n"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  python3 - "$TMP/$n.json" "$out_dir/manifest.txt" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
lines = []
for c in d['commands']:
  t = c.get('type')
  if t == 'module':
    lines.append('valid ' + c['filename'])
  elif t in ('assert_invalid', 'assert_malformed') and c.get('module_type') == 'binary':
    kind = 'invalid' if t == 'assert_invalid' else 'malformed'
    lines.append(kind + ' ' + c['filename'])
with open(dst, 'w') as f:
  f.write('\n'.join(lines) + '\n')
PY

  while read -r line; do
    file="${line##* }"
    if [[ "$file" == *.wasm ]]; then
      cp "$TMP/$file" "$out_dir/"
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_v1_carry_over] re-baked: ${NAMES[*]}"
