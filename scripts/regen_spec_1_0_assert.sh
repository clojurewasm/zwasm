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
  unreachable
  local_get
  local_set
  int_literals
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

  if ! ( cd "$TMP" && wast2json \
      --enable-function-references \
      --enable-tail-call \
      --enable-extended-const \
      --enable-multi-memory \
      "$src" -o "$n.json" >/dev/null 2>&1 ); then
    echo "[regen_spec_1_0_assert] skip $n (wast2json rejected)" >&2
    rm -rf "$TMP"
    trap - EXIT
    continue
  fi

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
        # 7.5-close-d: relax arg filter to allow f32/f64 alongside
        # i32/i64. Runner dispatches the supported single-FP-arg
        # shapes; multi-arg + mixed-FP shapes still gate via the
        # `more-than-2-args` filter below.
        allowed_arg = lambda x: x['type'] in ('i32', 'i64', 'f32', 'f64')
        if not all(allowed_arg(x) for x in args):
            lines.append(f'skip non-int-arg {a["field"]}')
            continue
        # 7.5-close-c1: void-result (`expected: []`) flows through
        # via callVoid* helpers. 7.5-close-c2: f32/f64 single
        # results flow through via callF32* / callF64* helpers.
        # Multi-result (Wasm 2.0) still skip-impl pending runner
        # extension.
        if len(results) > 1 or any(r['type'] not in ('i32', 'i64', 'f32', 'f64') for r in results):
            lines.append(f'skip non-int-result {a["field"]}')
            continue
        # 7.5-close-mta: lift cap to 5; runner has callXX_<5-args>
        # helpers for the curated `(i64 f32 f64 i32 i32)` family
        # (local_get/set type-mixed/read/write fixtures).
        if len(args) > 5:
            lines.append(f'skip more-than-5-args {a["field"]}')
            continue
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        results_s = ' '.join(fmt(x) for x in results) if results else '()'
        lines.append(f'assert_return {a["field"]} {args_s} -> {results_s}')
    elif t == 'assert_trap':
        a = c['action']
        if a.get('type') != 'invoke':
            lines.append(f'skip trap-non-invoke')
            continue
        args = a.get('args', [])
        if any(x['type'] not in ('i32', 'i64') for x in args):
            lines.append(f'skip trap-non-int-arg {a["field"]}')
            continue
        if len(args) > 2:
            lines.append(f'skip trap-more-than-2-args {a["field"]}')
            continue
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'assert_trap {a["field"]} {args_s}')
    elif t == 'assert_invalid':
        # 7.5-close-a: well-formed-but-type-checking-failure cases.
        # Runner expects compileWasm to reject; matching the spec
        # `text` reason verbatim is fragile (zwasm validator
        # phrasing differs from upstream), so we drop it for now —
        # any rejection counts as PASS.
        lines.append(f'assert_invalid {c["filename"]}')
    elif t == 'assert_malformed':
        # 7.5-close-b: parser-level rejection (truly malformed
        # bytes, not just type-incorrect modules). Same runner
        # shape as assert_invalid; the rejection-or-accept signal
        # is what counts. wast2json may emit `module_type ==
        # 'text'` for .wast that doesn't decompile to .wasm —
        # those have no `filename` and we have to skip.
        if c.get('module_type') != 'binary' or 'filename' not in c:
            lines.append(f'skip directive-assert_malformed-text')
            continue
        lines.append(f'assert_malformed {c["filename"]}')
    else:
        lines.append(f'skip directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

  # Copy referenced .wasm files only (both `module ` directive
  # and `assert_invalid ` per 7.5-close-a — the latter references
  # malformed .wasm fixtures that the runner reads + validates).
  while read -r line; do
    set -- $line
    if [ "$1" = "module" ] || [ "$1" = "assert_invalid" ] || [ "$1" = "assert_malformed" ]; then
      cp "$TMP/$2" "$out_dir/"
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_spec_1_0_assert] re-baked: ${NAMES[*]} → $DEST/"
