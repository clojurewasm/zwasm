#!/usr/bin/env bash
# Regenerate Wasm 1.0 spec corpus with full assertion manifests
# (§9.7 / 7.5-spec-assertion-driver-a).
#
# wast2json bakes binary modules + commands JSON; this script
# distills the JSON into an extended manifest format the
# spec_assert_runner consumes:
#
#   module <file>                                  → load .wasm
#   assert_return <fn> <args> -> <results>         → invoke + compare
#
# args / results format: space-separated `<type>:<value>` tokens
# (i32:13). Empty args = `()`. Initial chunk-a covers ONLY
# i32→i32 with 0/1 args; other shapes emit `skip <reason>`.
#
# Drives §9.7 / 7.5 row toward `pass=fail=skip=0` from the
# 10/12 compile-success baseline.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_SPEC_REPO:-$HOME/Documents/OSS/WebAssembly/spec}
DEST=test/spec/wasm-1.0-assert

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_spec_1_0_assert] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_spec_1_0_assert] python3 not found" >&2
  exit 1
fi
if [ ! -d "$UPSTREAM/test/core" ]; then
  echo "[regen_spec_1_0_assert] upstream not found at $UPSTREAM/test/core" >&2
  exit 1
fi

# Curated chunk-a starter set: any .wast whose assert_returns
# are exclusively i32→i32 with ≤ 1 arg. Expand as the runner
# adds shapes (chunk-b: 2-arg; chunk-c: i64; …).
NAMES=(
  forward
)

mkdir -p "$DEST"

for n in "${NAMES[@]}"; do
  src="$UPSTREAM/test/core/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_spec_1_0_assert] missing $src" >&2
    exit 1
  fi
  TMP=$(mktemp -d)
  trap "rm -rf '$TMP'" EXIT

  ( cd "$TMP" && wast2json "$src" -o "$n.json" >/dev/null 2>&1 )

  out_dir="$DEST/$n"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  python3 - "$TMP/$n.json" "$out_dir/manifest.txt" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
def fmt(v):
    return f"{v['type']}:{v['value']}"
lines = []
for c in d['commands']:
    t = c.get('type')
    if t == 'module':
        lines.append('module ' + c['filename'])
    elif t == 'assert_return':
        a = c['action']
        if a.get('type') != 'invoke':
            lines.append(f'skip non-invoke-action')
            continue
        args = a.get('args', [])
        results = c.get('expected', [])
        # chunk-a: only i32 args + single i32 result.
        if any(x['type'] != 'i32' for x in args) or len(results) != 1 or results[0]['type'] != 'i32':
            lines.append(f'skip non-i32-shape {a["field"]}')
            continue
        if len(args) > 1:
            lines.append(f'skip more-than-1-arg {a["field"]}')
            continue
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        results_s = ' '.join(fmt(x) for x in results)
        lines.append(f'assert_return {a["field"]} {args_s} -> {results_s}')
    else:
        lines.append(f'skip directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

  # Copy referenced .wasm files only.
  while read -r line; do
    set -- $line
    if [ "$1" = "module" ]; then
      cp "$TMP/$2" "$out_dir/"
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_spec_1_0_assert] re-baked: ${NAMES[*]} → $DEST/"
