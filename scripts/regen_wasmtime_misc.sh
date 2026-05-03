#!/usr/bin/env bash
# Regenerate the wasmtime misc_testsuite curated corpus
# (BATCH1 basic + BATCH2 reftypes + BATCH3 embenchen + issues)
# under test/wasmtime_misc/wast/<category>/<fixture>/.
#
# Phase 6 / §9.6 / 6.C per ADR-0012. Each .wast is wast2json'd
# into a per-fixture subdir; the manifest.txt distils to the
# valid/invalid/malformed directives the wast_runner consumes
# (parse + validate gate). assert_return / assert_trap / etc.
# wire when 6.D drives the same corpus through the runtime-
# asserting runner.
#
# Usage:
#   bash scripts/regen_wasmtime_misc.sh
#
# Environment:
#   WASMTIME_REPO   — path to a wasmtime checkout. Defaults to
#                     $HOME/Documents/OSS/wasmtime. ADR-0012 §1
#                     authorises sparse-checkout to .cache/ for
#                     CI; this script just reads from any clone.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASMTIME_REPO:-$HOME/Documents/OSS/wasmtime}
DEST=test/wasmtime_misc/wast

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_wasmtime_misc] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_wasmtime_misc] python3 not found" >&2
  exit 1
fi
if [ ! -d "$UPSTREAM/tests/misc_testsuite" ]; then
  echo "[regen_wasmtime_misc] upstream not found at $UPSTREAM/tests/misc_testsuite" >&2
  echo "[regen_wasmtime_misc] set WASMTIME_REPO env var to override" >&2
  exit 1
fi

# Per ADR-0013 §2 + ADR-0012 §6.C. The classification mirrors v1
# convert.py's BATCH1-3 (basic ops / reference types / embenchen
# + issue-regression). BATCH4 (SIMD) and BATCH5 (proposals) defer
# per ADR-0012 §6.2.
BATCH1_BASIC=(
  add div-rem mul16-negative
  control-flow simple-unreachable
  misc_traps stack_overflow
  memory-copy imported-memory-copy partial-init-memory-segment
  call_indirect many-results many-return-values
  export-large-signature func-400-params table_copy
  table_copy_on_imported_tables elem-ref-null
  table_grow_with_funcref linking-errors empty
  # Queued for §9.6 / 6.E (v2 validator/interp gaps surfaced):
  #   wide-arithmetic, br-table-fuzzbug, no-panic, no-panic-on-invalid,
  #   elem_drop
)

BATCH2_REFTYPES=(
  f64-copysign float-round-doesnt-load-too-much
  sink-float-but-dont-trap externref-segment
  bit-and-conditions no-opt-panic-dividing-by-zero
  partial-init-table-segment rs2wasm-add-func
  # Queued for §9.6 / 6.E (v2 validator gaps — externref / GC):
  #   int-to-float-splat, externref-id-function,
  #   mutable_externref_globals, simple_ref_is_null,
  #   externref-table-dropped-segment-issue-8281,
  #   many_table_gets_lead_to_gc, no-mixup-stack-maps
)

BATCH3_EMBENCHEN=(
  embenchen_fannkuch embenchen_fasta embenchen_ifs
  embenchen_primes rust_fannkuch fib
)

BATCH3_ISSUES=(
  issue1809 issue4840 issue4857 issue4890
  issue694 issue11748 issue12318
  # Queued for §9.6 / 6.E:
  #   issue6562
)

skipped=()
landed=()

vendor_one() {
  local cat="$1" name="$2"
  local src="$UPSTREAM/tests/misc_testsuite/$name.wast"
  if [ ! -f "$src" ]; then
    skipped+=("$cat/$name (upstream missing)")
    return
  fi
  local out_dir="$DEST/$cat/$name"
  local TMP
  TMP=$(mktemp -d)

  if ! ( cd "$TMP" && wast2json \
      --enable-function-references \
      --enable-tail-call \
      --enable-extended-const \
      --enable-multi-memory \
      --enable-threads \
      "$src" -o "$name.json" >/dev/null 2>&1 ); then
    skipped+=("$cat/$name (wast2json failed)")
    rm -rf "$TMP"
    return
  fi

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  python3 - "$TMP/$name.json" "$out_dir/manifest.txt" <<'PY'
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

  if [ ! -s "$out_dir/manifest.txt" ]; then
    rm -rf "$out_dir"
    skipped+=("$cat/$name (no parse/validate-only directives)")
    rm -rf "$TMP"
    return
  fi

  while read -r line; do
    file="${line##* }"
    if [[ "$file" == *.wasm ]]; then
      if [ -f "$TMP/$file" ]; then
        cp "$TMP/$file" "$out_dir/"
      fi
    fi
  done < "$out_dir/manifest.txt"

  landed+=("$cat/$name")
  rm -rf "$TMP"
}

for n in "${BATCH1_BASIC[@]}";    do vendor_one basic    "$n"; done
for n in "${BATCH2_REFTYPES[@]}"; do vendor_one reftypes "$n"; done
for n in "${BATCH3_EMBENCHEN[@]}"; do vendor_one embenchen "$n"; done
for n in "${BATCH3_ISSUES[@]}";   do vendor_one issues   "$n"; done

echo "[regen_wasmtime_misc] landed: ${#landed[@]}"
for x in "${landed[@]}"; do echo "  $x"; done
echo "[regen_wasmtime_misc] skipped: ${#skipped[@]}"
for x in "${skipped[@]}"; do echo "  $x"; done
