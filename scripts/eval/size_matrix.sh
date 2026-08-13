#!/usr/bin/env bash
# scripts/eval/size_matrix.sh — measured binary size, zwasm and the comparison
# engines, on one host with one toolchain.
#
# Backs §2 of `.dev/meta_audits/2026-08-14-product-evaluation.md`.
#
# There is no CLI-only artifact to measure: `build.zig` roots the runtime at
# the `core` module, which is itself the root_module of libzwasm.a, and the CLI
# is a thin exe_mod that links it statically. And `libzwasm.a` is a 2-member
# archive, so archive size is a poor proxy for embedder cost. The comparable
# number is therefore the LINKED image of one minimal C host
# (docs/examples/c_host/hello.c) against each runtime's static library.
#
# Usage: bash scripts/eval/size_matrix.sh [outdir]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/private/eval/size}"
cd "$ROOT"
mkdir -p "$OUT/work"

sz()   { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
text() { size -A "$1" 2>/dev/null | awk '$1==".text"{print $2}'; }

TSV="$OUT/zwasm.tsv"
printf 'optimize\tengine\twasi\tcli\tcli_stripped\tcli_text\thost_stripped\thost_text\tlib\n' > "$TSV"

for opt in ReleaseFast ReleaseSmall; do
  for engine in interp jit both; do
    for wasi in none p1 p2 p3; do
      tag="${opt}_${engine}_${wasi}"
      lp="$OUT/work/lib_$tag"; cp="$OUT/work/cli_$tag"
      rm -rf "$lp" "$cp"

      lib=- ; host_s=- ; host_t=-
      if zig build static-lib -p "$lp" -Doptimize="$opt" -Dengine="$engine" \
           -Dwasi="$wasi" -Dcompiler-rt=true > "$OUT/work/$tag.lib.log" 2>&1; then
        lib="$(sz "$lp/lib/libzwasm.a")"
        if gcc -O2 -I "$lp/include" docs/examples/c_host/hello.c \
             "$lp/lib/libzwasm.a" -lm -Wl,-z,noexecstack \
             -o "$OUT/work/$tag.host" > "$OUT/work/$tag.host.log" 2>&1; then
          host_t="$(text "$OUT/work/$tag.host")"
          cp "$OUT/work/$tag.host" "$OUT/work/$tag.host.s"
          strip -s "$OUT/work/$tag.host.s"
          host_s="$(sz "$OUT/work/$tag.host.s")"
        fi
      fi

      cli=- ; cli_s=- ; cli_t=-
      # NOTE: `-Dstrip=true` is deliberately NOT used here — it crashes the
      # Zig 0.16.0 compiler on the installed spec-runner exes at both
      # ReleaseFast and ReleaseSafe (report §2.6). External `strip -s` gives
      # the same answer for the product binary.
      if zig build -p "$cp" -Doptimize="$opt" -Dengine="$engine" \
           -Dwasi="$wasi" > "$OUT/work/$tag.cli.log" 2>&1; then
        cli="$(sz "$cp/bin/zwasm")"; cli_t="$(text "$cp/bin/zwasm")"
        cp "$cp/bin/zwasm" "$cp/bin/zwasm.s"; strip -s "$cp/bin/zwasm.s"
        cli_s="$(sz "$cp/bin/zwasm.s")"
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$opt" "$engine" "$wasi" "$cli" "$cli_s" "$cli_t" "$host_s" "$host_t" "$lib" >> "$TSV"
      echo "[size] $tag" >&2
    done
  done
done

echo "=== zwasm ==="
column -t -s $'\t' "$TSV"

cat <<'NOTE'

=== comparison engines ===
Not built by this script — they need their own toolchains. Recipes used for
the report (see §0 for why the OFFICIAL wasmtime binaries are the fair rows):

  wasmtime  official release artifacts `wasmtime` and `wasmtime-min`
            (ci/build-release-artifacts.sh: panic=abort, strip=debuginfo;
             -min additionally needs nightly + -Zbuild-std + opt-level=s
             + lto=true + codegen-units=1 + -Zlocation-detail=none)

  WAMR      cmake -G Ninja product-mini/platforms/linux \
              -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
              [-DWAMR_BUILD_FAST_INTERP=0|1] [-DWAMR_BUILD_FAST_JIT=1] \
              [-DWAMR_BUILD_SIMD=0]
            NOTE: upstream WAMR rejects SIMD+CLASSIC_INTERP and SIMD+FAST_JIT
            at configure time, so those rows have no SIMD.

Compare with `strip -s` applied uniformly.
NOTE
