#!/usr/bin/env bash
# Regenerate the SIMD spec assertion corpus (§9.9 per ADR-0045).
#
# wast2json bakes binary modules + commands JSON; this script
# distills the JSON into the v128-aware extended manifest format
# the simd_assert_runner consumes:
#
#   module <file>                                   → load .wasm
#   assert_return <fn> <args> -> <results>          → invoke + compare
#   assert_invalid <file>                           → expect compile reject
#   assert_malformed <file>                         → expect parser reject
#   skip <reason>                                   → record as skipped
#
# args / results format (per ADR-0045 §"Decision" / 2):
#   <type>:<value>  for scalars (i32:13, f64:0x3ff8000000000000)
#   v128:<32 hex>   for v128 bit-pattern (lower-byte-first; matches
#                   the in-memory little-endian Wasm v128 layout —
#                   `bytes[0]` is lane-0-byte-0).
#
# §9.9-c (this commit) — populates the lightweight starter set
# (simd_address, simd_align, simd_const, simd_select) and emits
# fully-distilled manifests covering ()→v128, (i32)→v128, ()→f64,
# ()→() shapes that the runner can JIT-execute today. Shapes that
# require v128 PARAM marshal (deferred to §9.9-e) emit
# `skip v128-param-pending`.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_TESTSUITE_REPO:-$HOME/Documents/OSS/WebAssembly/testsuite}
DEST=test/spec/wasm-2.0-simd-assert

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_spec_simd_assert] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_spec_simd_assert] python3 not found" >&2
  exit 1
fi

# SIMD fixtures live at the testsuite root (not proposals/simd/);
# the SIMD proposal merged into core wasm-2.0 in 2021. ~57 simd*.wast
# files at the testsuite root.
if ! ls "$UPSTREAM"/simd_*.wast >/dev/null 2>&1; then
  echo "[regen_spec_simd_assert] no simd_*.wast files in $UPSTREAM" >&2
  exit 1
fi

# §9.9-c lightweight starter set per p9-9.9-survey.md §1.1.
# Total ~552 assertions across the four files; mix of ()→v128
# (199 + 6 + 4 = 209), (i32)→v128 (30 + 3 = 33), ()→f64 (60),
# ()→() (2), v128-param shapes (deferred) and assert_invalid /
# assert_malformed (375). 9.9-d will iterate to fail=skip=0 on
# this set; 9.9-e adds v128 PARAM; 9.9-f scales to FP arith.
NAMES=(
  simd_address
  simd_align
  simd_const
  simd_select
  # §9.9 / 9.9-f: scale to (v128, v128) → v128 binop fixtures.
  # simd_bitwise covers v128.{and, or, xor, andnot, not, bitselect}
  # — single-arch SSE2 instructions on x86_64 + NEON V.16B on ARM64,
  # all already wired in op_simd.zig dispatch.
  simd_bitwise
  # §9.9 / 9.9-f-4: scale to FP arith (1819 assertions in upstream).
  # Shapes: (v128, v128) → v128 (add/sub/mul/div), (v128) → v128
  # (neg/sqrt). Float ops already wired in 9.6/9.7 emit chunks.
  simd_f32x4_arith
  # §9.9 / 9.9-f-6: scale to f64x2 + int arith fixtures.
  # Same shapes as f32x4; ZirOps + emit handlers exist from
  # 9.5..9.7 cycles; lower-side wiring lands per chunk.
  simd_f64x2_arith
  simd_i32x4_arith
  simd_i16x8_arith
  simd_i8x16_arith
  simd_i64x2_arith
  # §9.9 / 9.9-g-2: scale corpus to int + FP cmp fixtures + lane.
  # All cmp opcodes (i*x* eq/ne/lt/gt/le/ge {s,u} + f*x* eq/ne/lt/
  # gt/le/ge) are dispatched in arm64/emit.zig already. Lane access
  # (splat/extract_lane/replace_lane for all 6 shapes) is wired.
  simd_i8x16_cmp
  simd_i16x8_cmp
  simd_i32x4_cmp
  simd_i64x2_cmp
  simd_f32x4_cmp
  simd_f64x2_cmp
  simd_lane
  # §9.9 / 9.9-g-5: scale corpus to v128.load*x*_* memory ops.
  # Sub-ops 1..6 are fully wired since §9.9-d-3 (load_extend
  # family).
  simd_load_extend
  # §9.9 / 9.9-g-6: int extend ops (134..137/166..169/199..202).
  # ZirOps + per-arch emit dispatch pre-existed; lower-side
  # wiring landed in 9.9-g-6.
  simd_int_to_int_extend
)

mkdir -p "$DEST"

for n in "${NAMES[@]}"; do
  src="$UPSTREAM/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_spec_simd_assert] missing $src" >&2
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
    echo "[regen_spec_simd_assert] skip $n (wast2json rejected)" >&2
    rm -rf "$TMP"
    trap - EXIT
    continue
  fi

  out_dir="$DEST/$n"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  python3 - "$TMP/$n.json" "$out_dir/manifest.txt" <<'PY'
import json, sys, struct

src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))

# v128 lane sizes (bytes) per wast2json's `lane_type` field.
LANE_SIZE = {
    "i8": 1, "i16": 2, "i32": 4, "i64": 8,
    "f32": 4, "f64": 8,
}

def encode_v128(value, lane_type):
    """wast2json emits v128 as a list of decimal-string lane values
    plus a `lane_type`. We pack each lane as a fixed-width little-
    endian integer (FP lanes ship as their bit pattern reinterpreted
    as int) and concatenate to 16 bytes — exactly the in-memory Wasm
    v128 layout. Output as 32-char lower-hex (lane-0-byte-0 first)."""
    sz = LANE_SIZE[lane_type]
    out = bytearray()
    for lane in value:
        # wast2json may emit "nan:canonical" / "nan:arithmetic" for
        # FP NaN lanes. The starter set (address/align/const/select)
        # uses concrete bit patterns only; surface NaN tokens as a
        # parse error so the caller can flip the directive to skip.
        if isinstance(lane, str) and lane.startswith("nan"):
            raise ValueError(f"nan-token-in-lane:{lane}")
        n = int(lane)
        # Mask to lane width (wast2json reports negative ints as
        # decimal strings; Python int conversion handles signedness
        # but `to_bytes` requires the unsigned modulo).
        if n < 0:
            n &= (1 << (sz * 8)) - 1
        out += n.to_bytes(sz, "little", signed=False)
    if len(out) != 16:
        raise ValueError(f"v128 length {len(out)} != 16")
    return out.hex()

def fmt_scalar(v):
    return f"{v['type']}:{v['value']}"

def fmt_token(v):
    """Format a single arg / result token for the manifest. Returns
    `None` if the lane carries an unsupported NaN-pattern (caller
    converts the directive to a skip)."""
    t = v["type"]
    if t in ("i32", "i64", "f32", "f64"):
        return fmt_scalar(v)
    if t == "v128":
        try:
            hex_s = encode_v128(v["value"], v["lane_type"])
        except ValueError as e:
            return f"!{e}"
        return f"v128:{hex_s}"
    return f"!unsupported-type:{t}"

# Shape gate: which (args, results) signatures the §9.9-c runner
# can JIT-execute. Keep tight; new shapes land as the entry-helper
# table grows in §9.9-e+.
SUPPORTED = {
    ((), ("i32",)): True,
    ((), ("i64",)): True,
    ((), ("f32",)): True,
    ((), ("f64",)): True,
    ((), ("v128",)): True,
    ((), ()): True,
    (("i32",), ("v128",)): True,
    (("i32",), ("i32",)): True,
    # §9.9 / 9.9-f: (v128, v128) → v128 binop shape (FP arith /
    # int arith / bitwise fixtures). Entry helper:
    # `entry.callV128_v128v128`.
    (("v128", "v128"), ("v128",)): True,
    # §9.9 / 9.9-f-4: (v128) → v128 unop shape (neg / sqrt /
    # abs / popcnt / extend_low / etc.). Entry helper:
    # `entry.callV128_v128`.
    (("v128",), ("v128",)): True,
}

lines = []
for c in d["commands"]:
    t = c.get("type")
    if t == "module":
        lines.append("module " + c["filename"])
    elif t == "assert_return":
        a = c["action"]
        if a.get("type") != "invoke":
            lines.append("skip non-invoke-action")
            continue
        args = a.get("args", [])
        results = c.get("expected", [])
        sig = (tuple(x["type"] for x in args), tuple(r["type"] for r in results))
        if sig not in SUPPORTED:
            # Distinguish v128-param from "no entry helper for this
            # shape" so 9.9-e + later widening can grep the manifests
            # for the specific gap.
            if any(t == "v128" for t in sig[0]):
                lines.append(f"skip v128-param-pending {a['field']}")
            else:
                lines.append(f"skip unsupported-shape {sig[0]}->{sig[1]} {a['field']}")
            continue
        arg_toks = [fmt_token(x) for x in args]
        res_toks = [fmt_token(r) for r in results]
        bad = [tok for tok in (arg_toks + res_toks) if tok and tok.startswith("!")]
        if bad:
            lines.append(f"skip nan-or-bad-token {a['field']} {' '.join(bad)}")
            continue
        # The runner's directive parser splits on the first space
        # to extract `<fn> <args>`; export names containing spaces
        # (e.g. simd_align's `v128.load align=16`) collide with
        # that tokenisation and surface as ExportNotFound. The
        # runner-format extension to handle quoted names is
        # tracked separately; skip these so the manifest stays
        # clean.
        if " " in a["field"]:
            lines.append(f"skip export-name-has-spaces {a['field']!r}")
            continue
        args_s = " ".join(arg_toks) if arg_toks else "()"
        results_s = " ".join(res_toks) if res_toks else "()"
        lines.append(f"assert_return {a['field']} {args_s} -> {results_s}")
    elif t == "assert_invalid":
        lines.append(f"assert_invalid {c['filename']}")
    elif t == "assert_malformed":
        if c.get("module_type") != "binary" or "filename" not in c:
            lines.append("skip directive-assert_malformed-text")
            continue
        lines.append(f"assert_malformed {c['filename']}")
    elif t == "assert_trap":
        # v128-result trap detection is fine (Error.Trap is raised
        # at the entry helper level regardless of result type), but
        # the runner needs an `assert_trap` v128-result path. Skip
        # for §9.9-c; widen in §9.9-d.
        a = c["action"]
        lines.append(f"skip assert_trap-v128-pending {a.get('field', '?')}")
    else:
        lines.append(f"skip directive-{t}")

with open(dst, "w") as f:
    f.write("\n".join(lines) + "\n")
PY

  # Copy referenced .wasm files. `module ` / `assert_invalid` /
  # `assert_malformed` directives all reference distinct .wasm
  # files in the wast2json output; the runner reads them on demand.
  while read -r line; do
    set -- $line
    if [ "$1" = "module" ] || [ "$1" = "assert_invalid" ] || [ "$1" = "assert_malformed" ]; then
      cp "$TMP/$2" "$out_dir/"
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_spec_simd_assert] re-baked: ${NAMES[*]} → $DEST/"
