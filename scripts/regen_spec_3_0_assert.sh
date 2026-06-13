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
# GC corpus baking unlocked at cycle 90 by switching the baker from
# wabt's `wast2json` to `wasm-tools json-from-wast`. wabt 1.0.40/1.0.41
# do not parse GC syntax (`i8`/`i16`/`anyref`/`struct`/`sub`/etc.);
# wasm-tools 1.247.0 (already in flake.nix) does. All 18 gc/raw/*.wast
# probed clean at the baker level; whether they parse + validate +
# execute on zwasm depends on Phase 10.G impl progress (currently 0
# Zir ops — the bake step is no longer the gate).
declare -a SMOKE=(
    "memory64/address64"
    "memory64/align64"
    "memory64/load64"
    "memory64/memory_grow64"
    "memory64/memory_redundancy64"
    "memory64/memory_trap64"
    # D-324 — the bulk-op .wast files lack the `64` suffix the
    # original expansion keyed on and were never distilled; that
    # hole hid the mixed-idx-type validator/interp gaps.
    "memory64/memory_copy"
    "memory64/memory_fill"
    "memory64/memory_init"
    "memory64/float_memory64"
    "tail-call/return_call"
    # 10.TC cycle 80 — return_call_indirect spec corpus expansion.
    "tail-call/return_call_indirect"
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
    # 10.M cycle 73 — broaden remaining multi-memory coverage. The
    # D-195(b) bundle close (cycle 72) unblocked cross-instance
    # memory imports; these fixtures exercise wider corners (floats,
    # mixed imports, linking sequences, start funcs, store + traps).
    "multi-memory/float_exprs0"
    "multi-memory/float_exprs1"
    "multi-memory/float_memory0"
    "multi-memory/imports0"
    "multi-memory/imports1"
    "multi-memory/imports2"
    "multi-memory/imports3"
    "multi-memory/imports4"
    "multi-memory/linking0"
    "multi-memory/linking1"
    "multi-memory/linking2"
    "multi-memory/linking3"
    "multi-memory/start0"
    "multi-memory/store1"
    "multi-memory/traps0"
    # 10.G cycle 90 — full GC corpus, baker swap (wasm-tools).
    # Bake-discoverable but impl distance is large (ZIR ops, heap,
    # type-subtyping all yet to be wired). Spec runner will show
    # gc=N(fail=N) initially; subsequent cycles whittle down as
    # 10.G impl lands.
    "gc/array"
    "gc/array_copy"
    "gc/array_fill"
    "gc/array_init_data"
    "gc/array_init_elem"
    "gc/array_new_data"
    "gc/array_new_elem"
    "gc/binary-gc"
    "gc/br_on_cast"
    "gc/br_on_cast_fail"
    "gc/extern"
    "gc/i31"
    "gc/ref_cast"
    "gc/ref_eq"
    "gc/ref_test"
    "gc/struct"
    "gc/type-subtyping-invalid"
    "gc/type-subtyping"
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

    # Baker: `wasm-tools json-from-wast` (Bytecode Alliance, part of
    # the wasm-tools crate suite; same project as wasmparser/wasmtime).
    # Switched from wabt's `wast2json` per D-179 discharge — wabt
    # 1.0.40/1.0.41 do not support GC proposal syntax (i8/i16 packed
    # fields, anyref, struct), but wasm-tools 1.247.0 does. Output
    # JSON format is structurally identical (verified at cycle 90
    # bake-swap: command type counts match; .wasm filenames match
    # the source-stem.N.wasm convention). All wasm features enabled
    # by default — no equivalent of wabt's `--enable-all` flag
    # required. zwasm's own validator is the conformance check.
    if ! wasm-tools json-from-wast --wasm-dir "$tmp" "$src" -o "$tmp/$name.json" >"$tmp/w2j.err" 2>&1; then
        echo "[bake] $proposal/$name: wasm-tools json-from-wast rejected — see $tmp/w2j.err" >&2
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
    # Bake JSON value normalization (cycle 90 baker swap from wabt
    # wast2json → wasm-tools json-from-wast). wabt emits i32/i64
    # values as unsigned (4294967295); wasm-tools emits them as
    # signed (-1). Spec runner manifest parser expects unsigned —
    # normalize here to avoid a runner-side migration touching every
    # parse_value call site.
    val = v.get('value', '?')
    t = v['type']
    if t == 'i32' and isinstance(val, str) and val.startswith('-'):
        n = int(val)
        if n < 0:
            val = str(n + (1 << 32))
    elif t == 'i64' and isinstance(val, str) and val.startswith('-'):
        n = int(val)
        if n < 0:
            val = str(n + (1 << 64))
    return f"{t}:{val}"
lines = []
def norm_mid(mid):
    # wabt prefixes module ids with `$` (wast source-form); wasm-tools
    # strips the `$`. The runner expects `$X` per wast convention; add
    # back when missing.
    if mid and not mid.startswith('$'):
        return '$' + mid
    return mid

for c in d['commands']:
    t = c.get('type')
    if t == 'module':
        # 10.M-D195b cycle 72 — emit module-id when wast2json
        # carries the `name: $X` field (set by wast `(module $X …)`).
        # The id is used by `register` + asserts that reference the
        # module by tag (e.g. `(invoke $X "fn" …)`). Without it the
        # runner can only dispatch to the most-recent instance.
        # Cycle 90 baker swap (wasm-tools): id arrives bare; norm_mid
        # restores the `$` prefix.
        mname = norm_mid(c.get('name'))
        if mname:
            lines.append('module ' + mname + ' ' + c['filename'])
        else:
            lines.append('module ' + c['filename'])
    elif t == 'assert_return':
        a = c['action']
        if a.get('type') != 'invoke':
            lines.append('skip-impl non-invoke-action')
            continue
        # 10.M-D195b cycle 72 — when the action targets a tagged
        # module (`(invoke $M "fn" …)`), prefix the field with
        # `$M::` so the runner routes to the registered instance.
        amod = norm_mid(a.get('module'))
        field_tok = (amod + '::' + a['field']) if amod else a['field']
        args = a.get('args', [])
        results = c.get('expected', [])
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        results_s = ' '.join(fmt(x) for x in results) if results else '()'
        lines.append(f'assert_return {field_tok} {args_s} -> {results_s}')
    elif t == 'assert_trap':
        a = c['action']
        amod = norm_mid(a.get('module'))
        field_raw = a.get('field', '<non-invoke>')
        field_tok = (amod + '::' + field_raw) if amod else field_raw
        args = a.get('args', []) if a.get('type') == 'invoke' else []
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'assert_trap {field_tok} {args_s}')
    elif t == 'assert_invalid':
        lines.append(f'assert_invalid {c.get("filename", "<inline>")}')
    elif t == 'assert_uninstantiable':
        # D-200 — module compiles but TRAPS at instantiation (active
        # data/elem OOB after partial writes). The runner instantiates
        # it (expecting failure); partial writes to SHARED imported
        # memory/table persist (D-199), which later asserts depend on.
        if 'filename' in c:
            lines.append(f'assert_uninstantiable {c["filename"]}')
        else:
            lines.append('skip-impl directive-assert_uninstantiable-inline')
    elif t == 'assert_unlinkable':
        # cyc193 (D-198 bundle) — module is valid but fails to LINK
        # (import type/kind/limits mismatch). The runner instantiates it
        # against the linker (expecting failure); verifies the REJECT
        # direction of cross-module import subtyping (cyc192).
        if 'filename' in c:
            lines.append(f'assert_unlinkable {c["filename"]}')
        else:
            lines.append('skip-impl directive-assert_unlinkable-inline')
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
        # via invokeInstanceVoid. 10.M-D195b cycle 72 — `module` tag
        # routes to the registered instance, same as asserts.
        a = c.get('action', {})
        if a.get('type') != 'invoke':
            lines.append('skip-impl non-invoke-action')
            continue
        amod = norm_mid(a.get('module'))
        field_tok = (amod + '::' + a['field']) if amod else a['field']
        args = a.get('args', [])
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'invoke {field_tok} {args_s}')
    elif t == 'register':
        # 10.M-D195b cycle 70 — wast `(register "name" $module_id?)`
        # exports the most-recent module under `name` for subsequent
        # modules' imports to find via Linker.defineMemory /
        # defineFunc. wast2json's JSON shape: `{type:register, as:<name>}`
        # (plus optional `name:$module_id` when the wast uses
        # `(register "name" $m)`). Previously dropped as
        # `skip-impl directive-register`; runner picks up the name
        # at cycle 70 + does the actual cross-instance binding in
        # subsequent cycles.
        as_name = c.get('as', '?')
        lines.append(f'register {as_name}')
    else:
        lines.append(f'skip-impl directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

    # Copy referenced .wasm artifacts (module / assert_invalid /
    # assert_malformed) — same shape as the 1.0/2.0 bake.
    # 10.M-D195b cycle 72 — `module $<id> <path>` form: when $2 starts
    # with `$`, the path is $3 (not $2). assert_invalid/malformed only
    # ever take a single arg.
    # Cycle 90 baker swap: pipe each .wasm through `wasm-tools strip --all`
    # to remove the `name` custom section that wasm-tools emits by default.
    # The name section provokes a subtle parse / import-resolution issue
    # on cross-module fixtures (linking1.{1,2}, imports4.{1,3,4} etc.)
    # that didn't exist with wabt's output. Stripping is the surgical fix
    # — name sections carry no semantic info needed by the spec runner.
    copy_stripped() {
        local src="$1"
        local dst="$2"
        if [ -f "$src" ]; then
            wasm-tools strip --all "$src" -o "$dst" 2>/dev/null || cp "$src" "$dst"
        fi
    }
    while read -r line; do
        # shellcheck disable=SC2086
        set -- $line
        case "$1" in
            module)
                if [ "${2:0:1}" = '$' ]; then
                    copy_stripped "$tmp/$3" "$out_dir/$3"
                else
                    copy_stripped "$tmp/$2" "$out_dir/$2"
                fi
                ;;
            assert_invalid|assert_malformed|assert_uninstantiable|assert_unlinkable)
                copy_stripped "$tmp/$2" "$out_dir/$2" ;;
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
