#!/usr/bin/env bash
# Regenerate Wasm 3.0 spec corpus with full assertion manifests.
# Companion to `scripts/regen_spec_{1,2}_0_assert.sh`; same
# wast2json + python distill pipeline, but consumes the
# `test/spec/wasm-3.0-assert/<proposal>/raw/` corpus imported by
# `scripts/import_proposal_corpus.sh` (10.T-1).
#
# 10.T-2a — smoke bake of 1 canonical wast per proposal to
# validate the wast2json pipeline against the 5 Wasm 3.0 corpora.
# Full bake + runner skeleton is 10.T-2b territory (when
# `spec_assert_runner_wasm_3_0.zig` exists to consume the
# manifests).
#
# Usage:
#   bash scripts/regen_spec_3_0_assert.sh
#       Bake the curated smoke set (1 wast/proposal) into
#       `test/spec/wasm-3.0-assert/<proposal>/<name>/`.
#   bash scripts/regen_spec_3_0_assert.sh <proposal> <name>
#       Bake a specific .wast (must exist in raw/).
#
# Per Phase 10 design plan §4.6 corpus 取り込み手順 step 2.

set -euo pipefail
cd "$(dirname "$0")/.."

DEST_ROOT=test/spec/wasm-3.0-assert

if ! command -v wast2json >/dev/null 2>&1; then
    echo "[regen_spec_3_0_assert] wast2json not in PATH (need wabt; nix develop?)" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[regen_spec_3_0_assert] python3 not in PATH" >&2
    exit 1
fi

# Smoke set: per-proposal smoke set anchoring the wast2json +
# manifest pipeline. memory64 expanded at 10.M-spec-corpus to
# cover the full set of memory64-specific .wast files (suffix
# `64`); other proposals still on the 1-wast smoke set
# (10.R / 10.TC / 10.E / 10.G full-corpus expand lands per-row).
# memory64.wast itself is excluded — uses non-standard
# `(module definition ...)` syntax that wast2json rejects.
#
# `gc/struct` is intentionally absent: upstream wabt 1.0.40
# (currently pinned in flake.nix) does NOT support GC proposal
# syntax in wast2json — `i8`/`i16`/`anyref`/`struct`/`sub`/etc.
# trigger "unexpected token" rejects. The GC corpus bakes when
# wabt is bumped to a release with full GC type support
# (upstream tracking issue: WebAssembly/wabt#2398-class). Until
# then `gc/` only has `raw/` .wast files available for manual
# reading; the runner's `gc 0 manifests` is the correct state.
declare -a SMOKE=(
    "memory64/address64"
    "memory64/align64"
    "memory64/load64"
    "memory64/memory_grow64"
    "memory64/memory_redundancy64"
    "memory64/memory_trap64"
    "tail-call/return_call"
    "exception-handling/try_table"
    "function-references/ref"
    # 10.M cycle 65 — multi-memory corpus (load/store via memidx > 0).
    # Subset chosen to exercise the cycle-64 interp routing without
    # depending on memory.size / memory.grow with memidx > 0 (still
    # rejected by `lower.zig::emitMemoryReserved` — separate cycle).
    "multi-memory/load0"
    # 10.M cycle 66 — multi-memory memory.size via memidx > 0 lands
    # (lower + validator + interp memidx routing).
    "multi-memory/memory_size0"
    # 10.M cycle 67 — bulk-op memidx > 0 (memory.copy / memory.fill /
    # memory.init). data0 exercises active-data memidx > 0;
    # memory_copy0 exercises explicit memory.copy memidx routing
    # (cross-memory copies between memidx 0 and 1).
    "multi-memory/data0"
    "multi-memory/memory_copy0"
    # 10.M cycle 68 — additional corpus coverage; surfaced the
    # frontendValidate data_count threading gap (fixed this cycle).
    # All exercises load/store/size/copy/fill/init at memidx > 0;
    # memory.init also requires the DataCount section (Wasm 2.0
    # §5.5.16) which the new fixtures all carry.
    "multi-memory/memory_init0"
    "multi-memory/memory_fill0"
    "multi-memory/store0"
    "multi-memory/load1"
    "multi-memory/align0"
    "multi-memory/address0"
    "multi-memory/memory_size1"
    # 10.M cycle 69 — broaden multi-memory coverage; all single-
    # module fixtures (no cross-module `(register …)` dependency).
    # Surfaces no new substrate gaps as of cycle 69 — pass-rate
    # contribution is mechanical.
    "multi-memory/address1"
    "multi-memory/binary0"
    "multi-memory/data1"
    "multi-memory/data_drop0"
    "multi-memory/exports0"
    "multi-memory/memory_size2"
    "multi-memory/memory_size3"
    "multi-memory/memory_trap0"
    "multi-memory/memory_trap1"
    "multi-memory/load2"
    "multi-memory/memory_copy1"
)

bake_one() {
    local proposal="$1"
    local name="$2"
    local src="$DEST_ROOT/$proposal/raw/$name.wast"

    if [ ! -f "$src" ]; then
        echo "[bake] $proposal/$name: missing $src (run import_proposal_corpus.sh --copy $proposal first)" >&2
        return 1
    fi

    local out_dir="$DEST_ROOT/$proposal/$name"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    # --enable-all covers all 5 proposals + their interactions
    # (e.g. EH × GC, tail-call × ref-types). wast2json's
    # decoder is permissive; the validator inside zwasm is
    # what enforces actual conformance.
    if ! wast2json --enable-all "$src" -o "$tmp/$name.json" >"$tmp/w2j.err" 2>&1; then
        echo "[bake] $proposal/$name: wast2json rejected — see $tmp/w2j.err" >&2
        cat "$tmp/w2j.err" >&2
        rm -rf "$tmp"
        return 1
    fi

    # Distill the JSON into the same manifest.txt format the
    # wasm-{1,2}.0-assert runners consume. Reuse the same
    # directive vocabulary; runner-specific filtering is
    # 10.T-2b's responsibility.
    python3 - "$tmp/$name.json" "$out_dir/manifest.txt" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
def fmt(v):
    return f"{v['type']}:{v.get('value','?')}"
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
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        results_s = ' '.join(fmt(x) for x in results) if results else '()'
        lines.append(f'assert_return {a["field"]} {args_s} -> {results_s}')
    elif t == 'assert_trap':
        a = c['action']
        args = a.get('args', []) if a.get('type') == 'invoke' else []
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        field = a.get('field', '<non-invoke>')
        lines.append(f'assert_trap {field} {args_s}')
    elif t == 'assert_invalid':
        lines.append(f'assert_invalid {c.get("filename", "<inline>")}')
    elif t == 'assert_malformed':
        if c.get('module_type') == 'binary' and 'filename' in c:
            lines.append(f'assert_malformed {c["filename"]}')
        else:
            lines.append('skip-adr-skip_text_format_parser directive-assert_malformed-text')
    elif t == 'assert_exception':
        a = c.get('action', {})
        args = a.get('args', []) if a.get('type') == 'invoke' else []
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        field = a.get('field', '<non-invoke>')
        lines.append(f'assert_exception {field} {args_s}')
    elif t == 'action':
        # D-191 — wast `(invoke "fn" args)` action directive between
        # asserts. Side-effect driver for state-dependent sequences
        # (e.g. memory_redundancy64's `zero_everything` call between
        # test_store_to_load and test_redundant_load). Previously
        # dropped as `skip-impl directive-action`; runner now invokes
        # via invokeInstanceVoid.
        a = c.get('action', {})
        if a.get('type') != 'invoke':
            lines.append('skip-impl non-invoke-action')
            continue
        args = a.get('args', [])
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'invoke {a["field"]} {args_s}')
    else:
        lines.append(f'skip-impl directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

    # Copy referenced .wasm artifacts (module / assert_invalid /
    # assert_malformed) — same shape as the 1.0/2.0 bake.
    while read -r line; do
        # shellcheck disable=SC2086
        set -- $line
        case "$1" in
            module|assert_invalid|assert_malformed)
                [ -f "$tmp/$2" ] && cp "$tmp/$2" "$out_dir/" ;;
        esac
    done < "$out_dir/manifest.txt"

    rm -rf "$tmp"
    trap - RETURN

    local n_mod n_ret n_trap
    n_mod=$(grep -c '^module ' "$out_dir/manifest.txt" || true)
    n_ret=$(grep -c '^assert_return ' "$out_dir/manifest.txt" || true)
    n_trap=$(grep -c '^assert_trap ' "$out_dir/manifest.txt" || true)
    printf "[bake] %-22s %-15s module=%-3s return=%-4s trap=%-3s\n" \
        "$proposal" "$name" "$n_mod" "$n_ret" "$n_trap"
}

if [ $# -eq 2 ]; then
    bake_one "$1" "$2"
else
    for entry in "${SMOKE[@]}"; do
        proposal="${entry%/*}"
        name="${entry#*/}"
        bake_one "$proposal" "$name" || true
    done
fi
