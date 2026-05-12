#!/usr/bin/env bash
# Regenerate Wasm 2.0 non-SIMD spec corpus with full assertion
# manifests (§9.9 / 9.9-l-1b per ADR-0057). Parallel to
# `regen_spec_1_0_assert.sh`; same distillation pipeline,
# targeting wasm-2.0-specific .wast files (sign-ext, sat-trunc,
# select-typed, local_init, etc.). Consumed by the new
# `spec_assert_runner_non_simd` (`zig build test-spec-wasm-2.0-assert`).
#
# The starter set is curated for shapes the runner already handles:
#   - scalar (i32 / i64 / f32 / f64) args + results, no v128
#   - n_args ∈ {0, 1, 2, 5} (5-arg covers the `(i64 f32 f64 i32 i32)`
#     multi-value family)
#   - single-result (multi-result is skip-impl at the manifest level
#     via the `len(results) > 1` filter below).
#
# Expansion (k-1 row in the autonomous queue) adds:
#   - table_get / table_set / table_size / table_init / table_copy
#     (the m-2 cluster JIT support is in place; these need scalar
#     refnull handling on the runner side, deferred).
#   - bulk-memory / memory_init / memory_copy / memory_fill /
#     data_drop / elem_drop.
#   - block / loop / call multi-value fixtures (need multi-result
#     return-value packing in the runner; deferred).
#   - ref_func / ref_null / ref_is_null (need reftype handling).

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_SPEC_REPO:-$HOME/Documents/OSS/WebAssembly/spec}
DEST=test/spec/wasm-2.0-assert

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_spec_2_0_assert] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_spec_2_0_assert] python3 not found" >&2
  exit 1
fi
if [ ! -d "$UPSTREAM/test/core" ]; then
  echo "[regen_spec_2_0_assert] upstream not found at $UPSTREAM/test/core" >&2
  exit 1
fi

# Curated l-1b starter set. Wasm 2.0 features each name exercises:
#   conversions   — sign-extension (i32.extend8_s, i64.extend32_s, …)
#                   + non-trapping float-to-int (i32.trunc_sat_f32_s,
#                   i64.trunc_sat_f64_u, …).
#   local_init    — Wasm 2.0 local-init invariant
#                   (locals zero-initialised before any read).
# `select` is queued for the next chunk: the Wasm 2.0 typed-select
# corpus (select.wast) carries reftype-bearing assertions whose
# `module` directives compileWasm rejects with `BadValType` until
# reftype runtime support lands. Pulling it now would make the
# corpus FAIL non-stop on every cycle.
# Expansion candidates listed in the file header (table_*, ref_*,
# bulk-memory) need runner extensions or refnull handling that are
# out of l-1b scope (k-1 row in the autonomous queue).
# f32 / f64 re-enabled at D-092 close (§9.9 / 9.9-l-1b-d092-close):
# the x86_64 `emitFpMinMax` path rejected the regalloc-issued
# `dst == rhs and dst != lhs` case where `emitFpBinary` handled
# it (commutative-swap). Fix: min/max are commutative across all
# three branches (UCOMI / MINSS-MAXSS / ORPS-ANDPS / ADDSS), so
# swap lhs/rhs when dst aliases rhs. Three-host gate bit-identical.
NAMES=(
  conversions
  i32
  i64
  f32
  f64
  f32_cmp
  f64_cmp
  int_exprs
  int_literals
  float_literals
  unreachable
  local_get
  local_set
  return
)

mkdir -p "$DEST"

for n in "${NAMES[@]}"; do
  src="$UPSTREAM/test/core/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_spec_2_0_assert] missing $src" >&2
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
    echo "[regen_spec_2_0_assert] skip $n (wast2json rejected)" >&2
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
            lines.append('skip-impl non-invoke-action')
            continue
        args = a.get('args', [])
        results = c.get('expected', [])
        allowed_scalar = lambda x: x['type'] in ('i32', 'i64', 'f32', 'f64')
        if not all(allowed_scalar(x) for x in args):
            lines.append(f'skip-impl non-scalar-arg {a["field"]}')
            continue
        if len(results) > 1:
            lines.append(f'skip-impl multi-result {a["field"]}')
            continue
        if results and not allowed_scalar(results[0]):
            lines.append(f'skip-impl non-scalar-result {a["field"]}')
            continue
        # Filter against the runner's dispatch ladder (current
        # `spec_assert_runner_non_simd` shape; see
        # `dispatchScalarResult` + `dispatchVoidResult`).
        # Extending the ladder = a separate chunk that adds the
        # missing `entry.callXX_yy` helpers + the dispatch arms.
        arg_kinds = tuple(x['type'] for x in args)
        result_kind = results[0]['type'] if results else 'void'
        supported = {
            ((), 'i32'), ((), 'i64'), ((), 'f32'), ((), 'f64'),
            (('i32',), 'i32'), (('i32',), 'i64'),
            (('i64',), 'i64'), (('i64',), 'i32'),
            (('f32',), 'f32'),
            (('f64',), 'f64'),
            (('i32', 'i32'), 'i32'),
            # 9.9-l-1b-binop: i64 / f32 / f64 2-arg shapes
            # (binop + cmp families).
            (('i64', 'i64'), 'i64'),
            (('i64', 'i64'), 'i32'),
            (('f32', 'f32'), 'f32'),
            (('f32', 'f32'), 'i32'),
            (('f64', 'f64'), 'f64'),
            (('f64', 'f64'), 'i32'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'i64'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'f64'),
            # 9.9-l-1b-widen: cross-type scalar shapes (conversions.wast).
            (('f32',), 'i32'), (('f64',), 'i32'),
            (('f32',), 'i64'), (('f64',), 'i64'),
            (('i32',), 'f32'), (('i64',), 'f32'),
            (('i32',), 'f64'), (('i64',), 'f64'),
            (('f64',), 'f32'), (('f32',), 'f64'),
            # Void-result shapes:
            ((), 'void'),
            (('i32',), 'void'), (('i64',), 'void'),
            (('f32',), 'void'), (('f64',), 'void'),
            (('i32', 'i32'), 'void'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'void'),
        }
        if (arg_kinds, result_kind) not in supported:
            lines.append(
                f'skip-impl runner-shape-gap '
                f'({" ".join(arg_kinds) or "()"}, {result_kind}) {a["field"]}'
            )
            continue
        # 9.9-l-1b-nan: NaN-pattern result tokens
        # (`nan:canonical` / `nan:arithmetic`) flow through via
        # `base.parseScalarFpExpected` + `matchScalarF32/F64`. No
        # filter needed — the runner compares per the Wasm spec §A.2
        # NaN classes.
        # Trapping-trunc family flows through unfiltered. D-091
        # (§9.9 / 9.9-l-1b-d091-close) fixed the only x86_64
        # boundary-precision miscompile (`i32.trunc_f64_s`); the
        # other 3 signed variants' FP-precision step is coarser
        # than the half-step gap so the original `-2^N` / `JB`
        # bound is spec-conformant.
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        results_s = ' '.join(fmt(x) for x in results) if results else '()'
        lines.append(f'assert_return {a["field"]} {args_s} -> {results_s}')
    elif t == 'assert_trap':
        a = c['action']
        if a.get('type') != 'invoke':
            lines.append('skip-impl trap-non-invoke')
            continue
        args = a.get('args', [])
        # 9.9-l-1b-trap-widen: assert_trap dispatch covers
        # 0-arg + (i32) + (i64) + (i32,i32) + (f32) + (f64) shapes.
        # 2+-arg FP shapes still skip-impl until they surface in
        # a corpus that needs them.
        trap_supported = {
            (), ('i32',), ('i64',), ('f32',), ('f64',),
            ('i32', 'i32'),
            ('i64', 'i64'),
        }
        arg_kinds = tuple(x['type'] for x in args)
        if any(x['type'] not in ('i32', 'i64', 'f32', 'f64') for x in args):
            lines.append(f'skip-impl trap-non-scalar-arg {a["field"]}')
            continue
        if arg_kinds not in trap_supported:
            lines.append(
                f'skip-impl trap-shape-gap '
                f'({" ".join(arg_kinds) or "()"}) {a["field"]}'
            )
            continue
        # D-091 closed: trap-mode skip-adr removed in lockstep
        # with the assert_return arm above.
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'assert_trap {a["field"]} {args_s}')
    elif t == 'assert_invalid':
        lines.append(f'assert_invalid {c["filename"]}')
    elif t == 'assert_malformed':
        if c.get('module_type') != 'binary' or 'filename' not in c:
            lines.append('skip-adr-skip_text_format_parser directive-assert_malformed-text')
            continue
        lines.append(f'assert_malformed {c["filename"]}')
    else:
        lines.append(f'skip-impl directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

  # Copy referenced .wasm files (module, assert_invalid, assert_malformed).
  while read -r line; do
    set -- $line
    if [ "$1" = "module" ] || [ "$1" = "assert_invalid" ] || [ "$1" = "assert_malformed" ]; then
      if [ -f "$TMP/$2" ]; then
        cp "$TMP/$2" "$out_dir/"
      fi
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_spec_2_0_assert] re-baked: ${NAMES[*]} → $DEST/"
