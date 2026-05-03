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

  python3 - "$TMP/$name.json" "$out_dir/manifest.txt" "$out_dir/manifest_runtime.txt" <<'PY'
import json, sys
src, dst_parse, dst_rt = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
parse_lines = []
rt_lines = []

def encode_value(v):
  ty = v.get('type', '')
  raw = v.get('value', '')
  # wast2json emits ints as decimal strings; floats as bit-pattern
  # decimal strings (e.g. f32: "1234567890" representing the u32
  # IEEE 754 bit pattern). Wrap in TLV per ADR-0013 §2 syntax.
  if ty == 'i32':
    try:
      return f'i32:{int(raw)}'
    except Exception:
      return None
  if ty == 'i64':
    try:
      return f'i64:{int(raw)}'
    except Exception:
      return None
  if ty == 'f32':
    # raw is a u32 decimal of the bit pattern → emit hex form the
    # runner's parseValue accepts via the `f32:0xHEX` path.
    try:
      bits = int(raw)
      return f'f32:0x{bits:08x}'
    except Exception:
      return None
  if ty == 'f64':
    try:
      bits = int(raw)
      return f'f64:0x{bits:016x}'
    except Exception:
      return None
  # v128 / externref / funcref / null refs deferred — runtime
  # runner doesn't compare those yet. Returning None causes the
  # entire directive to be skipped from manifest_runtime.txt.
  return None

def encode_args(values):
  out = []
  for v in values or []:
    e = encode_value(v)
    if e is None:
      return None
    out.append(e)
  return out

def quote_field(field):
  # The runtime runner tokenises directives by whitespace, so any
  # export name carrying a space (`is hello?`, etc.) must be wrapped
  # in double quotes. Embedded double quotes are escaped with a
  # backslash; the runner's token reader unescapes them.
  if any(c in field for c in ' \t"'):
    return '"' + field.replace('\\', '\\\\').replace('"', '\\"') + '"'
  return field

for c in d['commands']:
  t = c.get('type')
  if t == 'module':
    fn = c['filename']
    parse_lines.append('valid ' + fn)
    line = 'module ' + fn
    name = c.get('name')
    if name:
      # wast2json emits a `$id` for `(module $id ...)`; preserve it
      # so a later `register` directive that references the module
      # by id resolves cleanly.
      line += ' as ' + quote_field(str(name))
    rt_lines.append(line)
  elif t == 'register':
    as_name = c.get('as', '')
    line = 'register ' + quote_field(as_name)
    name = c.get('name')
    if name:
      line += ' from ' + quote_field(str(name))
    rt_lines.append(line)
  elif t in ('assert_invalid', 'assert_malformed') and c.get('module_type') == 'binary':
    kind = 'invalid' if t == 'assert_invalid' else 'malformed'
    parse_lines.append(kind + ' ' + c['filename'])
  elif t in ('assert_unlinkable', 'assert_uninstantiable') and c.get('module_type') == 'binary':
    rt_lines.append(t + ' ' + c['filename'])
  elif t == 'assert_return':
    act = c.get('action', {})
    if act.get('type') != 'invoke':
      continue
    args = encode_args(act.get('args'))
    expected = encode_args(c.get('expected'))
    if args is None or expected is None:
      continue
    field = act.get('field', '')
    rt_line = 'assert_return ' + quote_field(field)
    if args:
      rt_line += ' ' + ' '.join(args)
    rt_line += ' -> ' + (' '.join(expected) if expected else '')
    rt_lines.append(rt_line.rstrip())
  elif t == 'action':
    # Bare `(invoke <field> <args>)` action lines mutate state
    # between asserts (memory.copy / table.copy etc.). Emit
    # them as `invoke <field> <args>` so the runtime runner
    # actually executes them; without this the asserts that
    # follow check stale memory/table state.
    act = c.get('action', {})
    if act.get('type') != 'invoke':
      continue
    args = encode_args(act.get('args'))
    if args is None:
      continue
    field = quote_field(act.get('field', ''))
    rt_line = 'invoke ' + field
    if args:
      rt_line += ' ' + ' '.join(args)
    rt_lines.append(rt_line.rstrip())
  elif t == 'assert_trap':
    act = c.get('action', {})
    if act.get('type') != 'invoke':
      continue
    args = encode_args(act.get('args'))
    if args is None:
      continue
    field = quote_field(act.get('field', ''))
    # Map wast2json's spec-text trap message to the v2 c_api
    # TrapKind tag the runner expects. Names are the v2-side
    # tag names (see test/runners/wast_runtime_runner.zig
    # trapKindName).
    spec_text = c.get('text', '')
    tag_map = {
      'unreachable': 'Unreachable',
      'integer divide by zero': 'DivByZero',
      'divide by zero': 'DivByZero',
      'integer overflow': 'IntOverflow',
      'invalid conversion to integer': 'InvalidConversionToInt',
      'out of bounds memory access': 'OutOfBounds',
      'out of bounds': 'OutOfBounds',
      'out of bounds table access': 'OutOfBoundsTableAccess',
      'uninitialized element': 'UninitializedElement',
      'indirect call type mismatch': 'IndirectCallTypeMismatch',
      'call stack exhausted': 'StackOverflow',
      # `undefined element` is the wast-spec name for table-OOB
      # accesses on bulk operations (table.copy / table.init).
      # `uninitialized element` is the call_indirect-on-null trap.
      # The two share wording in older wast files but map to
      # distinct v2 TrapKinds.
      'undefined element': 'OutOfBoundsTableAccess',
    }
    kind = tag_map.get(spec_text, 'Unreachable')
    rt_line = 'assert_trap ' + field
    if args:
      rt_line += ' ' + ' '.join(args)
    rt_line += ' !! ' + kind
    rt_lines.append(rt_line)

with open(dst_parse, 'w') as f:
  f.write('\n'.join(parse_lines) + '\n')
with open(dst_rt, 'w') as f:
  f.write('\n'.join(rt_lines) + '\n')
PY

  if [ ! -s "$out_dir/manifest.txt" ]; then
    rm -rf "$out_dir"
    skipped+=("$cat/$name (no parse/validate-only directives)")
    rm -rf "$TMP"
    return
  fi

  # Walk both manifests so .wasm files referenced only by
  # manifest_runtime.txt directives (e.g. `assert_uninstantiable`)
  # also get copied into out_dir.
  for src_manifest in "$out_dir/manifest.txt" "$out_dir/manifest_runtime.txt"; do
    [ -f "$src_manifest" ] || continue
    while read -r line; do
      for tok in $line; do
        if [[ "$tok" == *.wasm ]]; then
          if [ -f "$TMP/$tok" ] && [ ! -f "$out_dir/$tok" ]; then
            cp "$TMP/$tok" "$out_dir/"
          fi
        fi
      done
    done < "$src_manifest"
  done

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
