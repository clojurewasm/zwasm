#!/usr/bin/env bash
# Regenerate the curated Wasm 2.0 corpus from the upstream
# WebAssembly/spec testsuite. For each .wast file in NAMES below,
# wast2json bakes binary modules + commands JSON; the script
# distils the JSON into a flat manifest the wast_runner consumes.
#
# Phase 2 / §9.2 / 2.8: corpus expansion is iterative — adding a
# .wast file here surfaces validator gaps for the runner to fail
# loudly. Names are curated to keep the gate green; entries land
# only when their .wasms pass.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_SPEC_REPO:-$HOME/Documents/OSS/WebAssembly/spec}
DEST=test/spec/wasm-2.0

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_test_data_2_0] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_test_data_2_0] python3 not found" >&2
  exit 1
fi
if [ ! -d "$UPSTREAM/test/core" ]; then
  echo "[regen_test_data_2_0] upstream not found at $UPSTREAM/test/core" >&2
  echo "[regen_test_data_2_0] set WASM_SPEC_REPO env var to override" >&2
  exit 1
fi

# Curated set: each name corresponds to one .wast file. Add a name
# only when its modules pass / its assert_invalids correctly fail.
NAMES=(
  const
  nop
  unreachable
  br
  return
  call
  labels
  switch
  unwind
  forward
  local_get
  local_set
  stack
)

for n in "${NAMES[@]}"; do
  src="$UPSTREAM/test/core/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_test_data_2_0] missing $src" >&2
    exit 1
  fi
  TMP=$(mktemp -d)
  trap "rm -rf '$TMP'" EXIT

  ( cd "$TMP" && wast2json "$src" -o "$n.json" >/dev/null 2>&1 )

  out_dir="$DEST/$n"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  python3 - "$TMP/$n.json" "$out_dir/manifest.txt" <<'PY'
import json, os, sys
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

  # Copy referenced .wasm files only (skip .wat).
  while read -r line; do
    file="${line##* }"
    if [[ "$file" == *.wasm ]]; then
      cp "$TMP/$file" "$out_dir/"
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_test_data_2_0] re-baked: ${NAMES[*]}"
