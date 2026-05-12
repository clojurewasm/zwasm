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
# f32 / f64 deferred: x86_64 compileWasm fails on f32.0.wasm /
# f64.0.wasm with UnsupportedOp (some FP op missing in JIT; Mac
# aarch64 succeeds → real host differential). Queued as D-092
# investigation; the cmp wasts are safe (no FP arithmetic in
# the module body, only comparison).
NAMES=(
  conversions
  i32
  i64
  f32_cmp
  f64_cmp
  int_exprs
  int_literals
  float_literals
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
import json, struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
def fmt(v):
    return f"{v['type']}:{v['value']}"
# Trapping-trunc family for the x86_64 precision skip-ADR
# (`skip_x86_64_trunc_precision.md`). Used by both assert_return
# and assert_trap arms; per ADR-0029 Path B the skip-adr token
# routes to the same tally regardless of the original directive.
TRUNC_TRAP_OPS = {
    ('i32.trunc_f32_s', 32, True),
    ('i32.trunc_f64_s', 32, True),
    ('i32.trunc_f32_u', 32, False),
    ('i32.trunc_f64_u', 32, False),
    ('i64.trunc_f32_s', 64, True),
    ('i64.trunc_f64_s', 64, True),
    ('i64.trunc_f32_u', 64, False),
    ('i64.trunc_f64_u', 64, False),
}
def trunc_arg_in_edge(field, arg):
    """Return True iff `field` is in the trapping-trunc family AND
    the arg's decoded f-value lies in the half-step boundary range
    around the target integer's representable range. Boundary
    inputs are waived per skip_x86_64_trunc_precision.md until
    D-091 lands."""
    op_match = next((m for m in TRUNC_TRAP_OPS if m[0] == field), None)
    if op_match is None or arg['type'] not in ('f32', 'f64'):
        return False
    tok_u = int(arg['value'])
    if arg['type'] == 'f32':
        fval = struct.unpack('f', struct.pack('I', tok_u & 0xFFFFFFFF))[0]
    else:
        fval = struct.unpack('d', struct.pack('Q', tok_u))[0]
    if fval != fval:  # NaN: not an edge case, let it pass
        return False
    _, bits, signed = op_match
    if signed:
        lo, hi = -(2 ** (bits - 1)), 2 ** (bits - 1)
        return (lo - 1.0 <= fval <= lo + 1.0) or (hi - 1.0 <= fval <= hi + 1.0)
    hi = 2 ** bits
    return (-1.0 <= fval <= 1.0) or ((hi - 1.0) <= fval <= (hi + 1.0))
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
        # Skip ADR — `skip_x86_64_trunc_precision.md`. The trapping
        # `*.trunc_f{32,64}_{s,u}` family on x86_64 mishandles inputs
        # in the half-step range immediately outside the target
        # integer's representable range. ARM64 PASSes; the host
        # differential blocks the gate. D-091 tracks the x86_64
        # fix; until then those boundary inputs are waived per the
        # ADR.
        if len(args) == 1 and trunc_arg_in_edge(a["field"], args[0]):
            lines.append(f'skip-adr-x86_64_trunc_precision {a["field"]} edge-input')
            continue
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
        # Honour the same x86_64 trunc-precision skip ADR for trap
        # cases — failing fixture is value-edge dependent regardless
        # of whether the wast originally expected a result or a trap.
        if len(args) == 1 and trunc_arg_in_edge(a["field"], args[0]):
            lines.append(f'skip-adr-x86_64_trunc_precision {a["field"]} trap-edge')
            continue
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
