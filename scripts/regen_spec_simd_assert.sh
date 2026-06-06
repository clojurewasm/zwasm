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
#   skip-impl <reason>                              → implementation gap; counts toward gate
#   skip-adr-<ADR-id> <reason>                      → design-deferred per named skip-ADR; waived
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
  # §9.9 / 9.9-g-6: int extend ops (135..138/167..170/199..202).
  # ZirOps + per-arch emit dispatch pre-existed; lower-side
  # wiring landed in 9.9-g-6 (off-by-one fixed at 9.9-g-7).
  simd_int_to_int_extend
  # §9.9 / 9.9-g-8: int shifts (107..109/139..141/171..173/
  # 203..205). shl wired in 9.9-g-7; shr_s/shr_u in 9.9-g-8 via
  # NEG-then-(U|S)SHL synthesis.
  simd_bit_shift
  # §9.9 / 9.9-g-10: secondary int arith — min/max/avgr/abs/popcnt
  # per shape. All ops wired since §9.7-au (int min/max/sat/avgr)
  # + 9.9-f-7 (abs/neg/popcnt). Cheap PASS gains expected; surfaces
  # any per-shape dispatch gap.
  simd_i8x16_arith2
  simd_i16x8_arith2
  simd_i32x4_arith2
  simd_i64x2_arith2
  # §9.9 / 9.9-g-10: any_true / all_true reductions (wired 9.9-g-3)
  # + bitmask (D-067 follow-up — multi-instr synthesis SSHR + AND
  # + ADDV; expected to fail compile until 9.9-g-N's bitmask chunk
  # lands). Surfaces D-067's exact scope.
  simd_boolean
  # §17.4 relaxed-SIMD (ADR-0169) — official conformance corpus. These use
  # `(either A B)` 2-outcome asserts (impl-defined per-arch latitude); the
  # distiller emits `either:<tokA>|<tokB>` and the runner accepts ANY outcome.
  i8x16_relaxed_swizzle
  i32x4_relaxed_trunc
  relaxed_madd_nmadd
  relaxed_laneselect
  relaxed_min_max
  i16x8_relaxed_q15mulr_s
  relaxed_dot_product
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
      --enable-relaxed-simd \
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
    v128 layout. Output as 32-char lower-hex (lane-0-byte-0 first).

    Raises ValueError if any lane is a NaN-pattern token
    (`nan:canonical` / `nan:arithmetic`); callers use that signal
    to emit the per-lane `v128_lanes:` form instead."""
    sz = LANE_SIZE[lane_type]
    out = bytearray()
    for lane in value:
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

# Per-lane NaN-pattern manifest form (chunk 9.9-h-25). Only the
# FP shapes f32x4 / f64x2 carry `nan:*` tokens (integer lanes are
# always bit-exact). Emitted as
#   v128_lanes:<shape>:<lane0>,<lane1>,...,<laneN>
# where <shape> ∈ {f32x4, f64x2} and each lane is:
#   c        — canonical NaN (sign-agnostic ±canonical)
#   a        — arithmetic NaN (any quiet NaN per spec)
#   V<hex>   — exact bit pattern (8 hex chars for f32, 16 for f64)
LANE_SHAPE = {"f32": ("f32x4", 4, 8), "f64": ("f64x2", 2, 16)}

def encode_v128_lanes(value, lane_type):
    """Emit a per-lane NaN-pattern manifest token. Only valid when
    `lane_type` is `f32` or `f64`; the caller restricts to that
    case after checking for nan tokens."""
    shape, n_lanes, hex_width = LANE_SHAPE[lane_type]
    if len(value) != n_lanes:
        raise ValueError(f"v128_lanes lane count {len(value)} != {n_lanes}")
    parts = []
    for lane in value:
        if lane == "nan:canonical":
            parts.append("c")
        elif lane == "nan:arithmetic":
            parts.append("a")
        else:
            # wast2json emits numeric lane values as decimal strings
            # (sometimes negative); int() parses both. Mask to the
            # lane width then format as natural-width hex.
            n = int(lane)
            mask = (1 << (hex_width * 4)) - 1
            n &= mask
            parts.append(f"V{n:0{hex_width}x}")
    return f"v128_lanes:{shape}:" + ",".join(parts)

def fmt_scalar(v):
    return f"{v['type']}:{v['value']}"

def has_nan_lane(v):
    if v.get("type") != "v128":
        return False
    return any(isinstance(lane, str) and lane.startswith("nan")
               for lane in v.get("value", []))

def result_type(r):
    """Result element type. `(either A B)` elements (relaxed-SIMD) carry
    no top-level `type`; all alternatives share one type, so read the
    first alternative's."""
    if "either" in r:
        return r["either"][0]["type"]
    return r["type"]

def fmt_token(v):
    """Format a single arg / result token for the manifest. Returns
    a string starting with `!` to signal an unsupported case (caller
    converts the directive to a skip)."""
    # §17.4 relaxed-SIMD `(either A B)` — 2+ permitted outcomes. Emit
    # `either:<tokA>|<tokB>`; the runner PASSes if `got` matches ANY.
    # Propagate a `!`-bad sub-token (e.g. nan-in-lane) to skip the row.
    if "either" in v:
        alts = [fmt_token(a) for a in v["either"]]
        for a in alts:
            if a.startswith("!"):
                return a
        return "either:" + "|".join(alts)
    t = v["type"]
    if t in ("i32", "i64", "f32", "f64"):
        return fmt_scalar(v)
    if t == "v128":
        lane_type = v.get("lane_type")
        # NaN-pattern lanes only appear in FP shapes; integer lanes
        # are always bit-exact (verified empirically — see 9.9-h-25
        # commit body). Emit the per-lane form only when needed.
        if has_nan_lane(v) and lane_type in ("f32", "f64"):
            try:
                return encode_v128_lanes(v["value"], lane_type)
            except ValueError as e:
                return f"!{e}"
        try:
            hex_s = encode_v128(v["value"], lane_type)
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
    # §9.9 / 9.9-h-14 (D-070 unblock): (v128, v128, v128) → v128
    # — bitselect / select corpus assertions. Entry helper:
    # `entry.callV128_v128v128v128`.
    (("v128", "v128", "v128"), ("v128",)): True,
    # §9.9 / 9.9-h-3 (D-079 (i)): v128 multi-arg setter shapes
    # — `(v128,) → ()`, `(v128, v128) → ()`, `(v128 ×4) → ()`.
    # Drives simd_const `as-global.set_value_$g*` exports.
    # Entry helpers: `callVoid_v128`, `callVoid_v128v128`,
    # `callVoid_v128v128v128v128`.
    (("v128",), ()): True,
    (("v128", "v128"), ()): True,
    (("v128", "v128", "v128", "v128"), ()): True,
    # chunk 9.9-h-26 (v128-param-pending discharge):
    # (v128,) → i32 — i*x*.all_true / any_true / bitmask /
    # i*x*.extract_lane.{s,u}. Entry helper: `entry.callI32_v128`.
    (("v128",), ("i32",)): True,
    # chunk 9.9-h-26: (v128,) → f32 — f32x4.extract_lane.
    # Entry helper: `entry.callF32_v128`.
    (("v128",), ("f32",)): True,
    # chunk 9.9-h-26: (v128,) → f64 — f64x2.extract_lane.
    # Entry helper: `entry.callF64_v128`.
    (("v128",), ("f64",)): True,
    # chunk 9.9-h-26: (v128, i32) → v128 — i*x*.shl / shr_s /
    # shr_u AND i*x*.replace_lane (value = i32, lane in opcode).
    # Entry helper: `entry.callV128_v128i32`.
    (("v128", "i32"), ("v128",)): True,
    # chunk 9.9-h-26: (v128, f32) → v128 — f32x4.replace_lane.
    # Entry helper: `entry.callV128_v128f32`.
    (("v128", "f32"), ("v128",)): True,
    # chunk 9.9-h-26: (v128, f64) → v128 — f64x2.replace_lane.
    # Entry helper: `entry.callV128_v128f64`.
    (("v128", "f64"), ("v128",)): True,
    # chunk 9.9-h-27 (v128-param-pending residual discharge):
    # (v128,) → i64 — i64x2.extract_lane (lane in opcode
    # immediate). Entry helper: `entry.callI64_v128`.
    (("v128",), ("i64",)): True,
    # chunk 9.9-h-27: (v128, i64) → v128 — i64x2.replace_lane
    # (i64 value; lane in opcode). Entry helper:
    # `entry.callV128_v128i64`.
    (("v128", "i64"), ("v128",)): True,
    # chunk 9.9-h-27: (v128, v128) → i32 — composite
    # `*_with_v128.{and,or,xor}` / `*_as_i32.*_operand` exports
    # whose body does `(any_true|all_true)(v128 op v128)` and
    # returns i32. Entry helper: `entry.callI32_v128v128`.
    (("v128", "v128"), ("i32",)): True,
    # chunk 9.9-h-31 (D-083 part 2 close): (v128, v128, i32) →
    # v128 — `select_v128_i32`. Entry helper:
    # `entry.callV128_v128v128i32`. arm64 fix landed at h-30
    # (V31 alias-stash in `arm64/op_simd.emitV128Select`);
    # x86_64 fix lands at h-31 (mask-based PAND/PXOR sequence
    # in `x86_64/op_simd.emitV128Select` with XMM7 mask + XMM14
    # tmp + XOR-trick to handle dst==val1 / dst==val2 aliases).
    (("v128", "v128", "i32"), ("v128",)): True,
    # chunk 9.9-h-28 (v128-param-pending residual discharge):
    # (v128, v128, v128) → i32 — `simd_boolean`
    # `*_with_v128.bitselect` (any_true/all_true of bitselect).
    # Entry helper: `entry.callI32_v128v128v128`.
    (("v128", "v128", "v128"), ("i32",)): True,
    # chunk 9.9-h-28: (v128, i32) → i32 — `simd_lane`
    # `i*x*_replace_lane-{s,u}` (replace lane + extract back) and
    # `as-i*x*_any_true-operand`. Entry helper: `entry.callI32_v128i32`.
    (("v128", "i32"), ("i32",)): True,
    # chunk 9.9-h-28: (v128, i64) → i32 — `simd_lane`
    # `as-i32x4_any_true-operand2`. Entry helper:
    # `entry.callI32_v128i64`.
    (("v128", "i64"), ("i32",)): True,
    # chunk 9.9-h-28: (v128, i64) → i64 — `simd_lane`
    # `i64x2_replace_lane`. Entry helper: `entry.callI64_v128i64`.
    (("v128", "i64"), ("i64",)): True,
    # chunk 9.9-h-28: (v128, f32) → f32 — `simd_lane`
    # `f32x4_replace_lane`. Entry helper: `entry.callF32_v128f32`.
    (("v128", "f32"), ("f32",)): True,
    # chunk 9.9-h-28: (v128, f64) → f64 — `simd_lane`
    # `f64x2_replace_lane`. Entry helper: `entry.callF64_v128f64`.
    (("v128", "f64"), ("f64",)): True,
    # chunk 9.9-h-28: (v128, v128, v128, v128) → v128 —
    # `simd_lane` `swizzle-as-i8x16_add-operands` /
    # `shuffle-as-i8x16_sub-operands`. Entry helper:
    # `entry.callV128_v128v128v128v128`.
    (("v128", "v128", "v128", "v128"), ("v128",)): True,
    # chunk 9.9-h-28: (v128, i32, v128) → v128 — `simd_lane`
    # `as-v8x16_swizzle-operand`. Entry helper:
    # `entry.callV128_v128i32v128`.
    (("v128", "i32", "v128"), ("v128",)): True,
    # chunk 9.9-h-28: (v128, i32, v128, i32) → v128 — `simd_lane`
    # `as-v8x16_shuffle-operands` / `as-i*x*_add-operands`. Entry
    # helper: `entry.callV128_v128i32v128i32`.
    (("v128", "i32", "v128", "i32"), ("v128",)): True,
    # chunk 9.9-h-28: (v128, i64, v128, i64) → v128 — `simd_lane`
    # `as-i64x2_add-operands`. Entry helper:
    # `entry.callV128_v128i64v128i64`.
    (("v128", "i64", "v128", "i64"), ("v128",)): True,
    # chunk 9.9-h-28: (i32, v128) → () — `simd_align`
    # `v128.store align=16` (address + value, void return). Entry
    # helper: `entry.callVoid_i32v128`.
    (("i32", "v128"), ()): True,
    # chunk 9.9-h-29 Part A (assert_trap discharge): (i32) → () —
    # `simd_address` `store_data_6` OOB-trap fixture. Entry
    # helper: `entry.callVoid_i32`.
    (("i32",), ()): True,
}

lines = []
for c in d["commands"]:
    t = c.get("type")
    if t == "module":
        lines.append("module " + c["filename"])
    elif t == "assert_return":
        a = c["action"]
        if a.get("type") != "invoke":
            lines.append("skip-impl non-invoke-action")
            continue
        args = a.get("args", [])
        # §17.4 relaxed-SIMD: wast2json puts the `(either A B …)` 2+-outcome
        # expectation in a TOP-LEVEL command key `either`, not in `expected`.
        # Wrap it into one synthetic result element so result_type + fmt_token's
        # either-branch handle it (each alt may be a nan-lane v128_lanes form).
        if "either" in c:
            results = [{"either": c["either"]}]
        else:
            results = c.get("expected", [])
        sig = (tuple(x["type"] for x in args), tuple(result_type(r) for r in results))
        if sig not in SUPPORTED:
            # Distinguish v128-param from "no entry helper for this
            # shape" so 9.9-e + later widening can grep the manifests
            # for the specific gap.
            if any(t == "v128" for t in sig[0]):
                lines.append(f"skip-impl v128-param-pending {a['field']}")
            else:
                lines.append(f"skip-impl unsupported-shape {sig[0]}->{sig[1]} {a['field']}")
            continue
        arg_toks = [fmt_token(x) for x in args]
        res_toks = [fmt_token(r) for r in results]
        bad = [tok for tok in (arg_toks + res_toks) if tok and tok.startswith("!")]
        if bad:
            lines.append(f"skip-impl nan-or-bad-token {a['field']} {' '.join(bad)}")
            continue
        # Export names containing spaces (e.g. simd_align's
        # `v128.load align=16`) emit as a single-quoted token; the
        # runner's tokeniser splits on the closing quote so the
        # space-bearing name reaches `findExportFunc` intact (chunk
        # 9.9-h-29 Part B discharge).
        fn_tok = f"'{a['field']}'" if " " in a["field"] else a["field"]
        args_s = " ".join(arg_toks) if arg_toks else "()"
        results_s = " ".join(res_toks) if res_toks else "()"
        lines.append(f"assert_return {fn_tok} {args_s} -> {results_s}")
    elif t == "assert_invalid":
        lines.append(f"assert_invalid {c['filename']}")
    elif t == "assert_malformed":
        if c.get("module_type") != "binary" or "filename" not in c:
            lines.append("skip-adr-skip_text_format_parser directive-assert_malformed-text")
            continue
        lines.append(f"assert_malformed {c['filename']}")
    elif t == "assert_trap":
        # Chunk 9.9-h-29 Part A — emit a real `assert_trap` directive
        # rather than a skip. The entry helpers raise `Error.Trap`
        # uniformly regardless of declared result type, so the only
        # call-shape gate is the arg signature; the result-type list
        # is ignored at dispatch time (a successful invoke with any
        # value is still a FAIL because no trap fired).
        a = c["action"]
        if a.get("type") != "invoke":
            lines.append("skip-impl non-invoke-action")
            continue
        args = a.get("args", [])
        # `assert_trap` dispatch is keyed off arg-shape only; the
        # declared result list determines which `callV*` to invoke
        # in the runner but Error.Trap propagates uniformly. Apply
        # the same SUPPORTED gate as assert_return so unsupported
        # arg shapes (e.g. v128 param) are surfaced specifically.
        results = c.get("expected", [])
        sig = (tuple(x["type"] for x in args), tuple(result_type(r) for r in results))
        if sig not in SUPPORTED:
            if any(t == "v128" for t in sig[0]):
                lines.append(f"skip-impl v128-param-pending {a['field']}")
            else:
                lines.append(f"skip-impl assert_trap-unsupported-shape {sig[0]}->{sig[1]} {a['field']}")
            continue
        arg_toks = [fmt_token(x) for x in args]
        bad = [tok for tok in arg_toks if tok and tok.startswith("!")]
        if bad:
            lines.append(f"skip-impl nan-or-bad-token {a['field']} {' '.join(bad)}")
            continue
        fn_tok = f"'{a['field']}'" if " " in a["field"] else a["field"]
        args_s = " ".join(arg_toks) if arg_toks else "()"
        # Declare the result shape in the directive so the runner
        # picks the right `callV*` helper (the helper still raises
        # Trap on OOB regardless of result type, but its calling
        # convention differs by result kind).
        res_toks = [r["type"] for r in results]
        results_s = " ".join(res_toks) if res_toks else "()"
        lines.append(f"assert_trap {fn_tok} {args_s} -> {results_s}")
    else:
        lines.append(f"skip-impl directive-{t}")

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
