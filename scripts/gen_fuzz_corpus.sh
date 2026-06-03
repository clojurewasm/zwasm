#!/usr/bin/env bash
# Generate the fuzz corpus (§14.3 / D-256).
#
#   bash scripts/gen_fuzz_corpus.sh [seed|campaign] [out-dir]
#     seed     (default): small COMMITTED smoke corpus (test/fuzz/corpus/seed/)
#                          — runs in `zig build test-fuzz` / test-all on the
#                          toolchain-free test hosts.
#     campaign: large GITIGNORED corpus (test/fuzz/corpus/campaign/) for the
#                          §14.3 nightly overnight campaign. `FUZZ_N=<n>` overrides.
#
# Mac-host only (needs `wasm-tools` from `nix develop`; the test hosts run the
# committed seed corpus through the Zig-built loader, no toolchain). Modules are
# generated DETERMINISTICALLY (seed index → fixed-PRNG bytes → `wasm-tools smith`)
# so the committed corpus is reproducible.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-seed}"
case "$MODE" in
  seed)     OUT="${2:-test/fuzz/corpus/seed}";     N=24 ;;
  campaign) OUT="${2:-test/fuzz/corpus/campaign}"; N="${FUZZ_N:-2000}" ;;
  *) echo "usage: $0 [seed|campaign] [out-dir]" >&2; exit 2 ;;
esac

command -v wasm-tools >/dev/null 2>&1 || { echo "[gen_fuzz_corpus] wasm-tools not on PATH (need 'nix develop')" >&2; exit 1; }
command -v python3   >/dev/null 2>&1 || { echo "[gen_fuzz_corpus] python3 not on PATH" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# Deterministic `wasm-tools smith` modules: seed index → 256 fixed-PRNG bytes.
for i in $(seq 0 $((N - 1))); do
  python3 -c "import sys,random; random.seed($i); sys.stdout.buffer.write(bytes(random.randrange(256) for _ in range(256)))" \
    | wasm-tools smith -o "$OUT/smith_$(printf '%04d' "$i").wasm" 2>/dev/null || true
done

# Hand-malformed blobs — exercise the reject-not-crash contract.
printf '\x00\x61\x73\x6d'                                         > "$OUT/malformed_magic_only.wasm"
printf '\xde\xad\xbe\xef\x01\x00\x00\x00'                         > "$OUT/malformed_bad_magic.wasm"
printf '\x00\x61\x73\x6d\x01\x00\x00\x00\x99\x01\x00'             > "$OUT/malformed_bad_section_id.wasm"
printf '\x00\x61\x73\x6d\x01\x00\x00\x00\x01\xff\xff\xff\xff\x0f' > "$OUT/malformed_oversize_seclen.wasm"
: > "$OUT/malformed_empty.wasm"

echo "[gen_fuzz_corpus] $MODE: $(find "$OUT" -type f | wc -l | tr -d ' ') files in $OUT"
