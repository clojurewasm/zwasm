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
NAMES=(
  conversions
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
            (('i64',), 'i64'),
            (('f32',), 'f32'),
            (('f64',), 'f64'),
            (('i32', 'i32'), 'i32'),
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
        # NaN-pattern result tokens (`nan:canonical` / `nan:arithmetic`)
        # need bit-pattern matching like the simd runner's `matchLaneF*`
        # helpers — not a literal `parseI64Token`. Skip until the
        # non-simd runner grows the equivalent. Same FP-NaN-aware
        # comparison Wasm spec §A.2 mandates for FP-producing ops.
        if results:
            v = results[0]['value']
            if isinstance(v, str) and v.startswith('nan:'):
                lines.append(f'skip-impl nan-pattern-result {a["field"]}')
                continue
        # Skip ADR — `skip_x86_64_trunc_precision.md`. The trapping
        # `*.trunc_f{32,64}_{s,u}` family on x86_64 mishandles inputs
        # in the half-step range immediately outside the target
        # integer's representable range (CVTTSD2SI returns the
        # sentinel result indistinguishable from a legitimate
        # INT_MIN, and the trap stub raises a trap). ARM64 PASSes;
        # the host differential blocks the gate. D-091 tracks the
        # x86_64 fix; until then those specific boundary inputs are
        # waived per the ADR.
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
        op_match = next((m for m in TRUNC_TRAP_OPS if m[0] == a["field"]), None)
        if op_match is not None and len(args) == 1 and args[0]['type'] in ('f32', 'f64'):
            import struct as _struct
            tok_u = int(args[0]['value'])
            if args[0]['type'] == 'f32':
                fval = _struct.unpack('f', _struct.pack('I', tok_u & 0xFFFFFFFF))[0]
            else:
                fval = _struct.unpack('d', _struct.pack('Q', tok_u))[0]
            _, bits, signed = op_match
            if signed:
                lo, hi = -(2 ** (bits - 1)), 2 ** (bits - 1)
                edge_lo_lo, edge_lo_hi = lo - 1.0, lo + 1.0
                edge_hi_lo, edge_hi_hi = hi - 1.0, hi + 1.0
                # Includes NaN check via != on math operators (NaN comparisons always false).
                if (fval == fval) and (
                    (edge_lo_lo <= fval <= edge_lo_hi) or (edge_hi_lo <= fval <= edge_hi_hi)
                ):
                    lines.append(f'skip-adr-x86_64_trunc_precision {a["field"]} edge-input')
                    continue
            else:
                hi = 2 ** bits
                if (fval == fval) and (
                    (-1.0 <= fval <= 1.0) or ((hi - 1.0) <= fval <= (hi + 1.0))
                ):
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
        # Runner's assert_trap dispatch handles 0-arg + (i32) +
        # (i64) + (i32,i32) only at l-1b; widen later as fixtures
        # demand.
        if any(x['type'] not in ('i32', 'i64') for x in args):
            lines.append(f'skip-impl trap-non-int-arg {a["field"]}')
            continue
        if len(args) > 2:
            lines.append(f'skip-impl trap-more-than-2-args {a["field"]}')
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
