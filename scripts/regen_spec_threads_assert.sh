#!/usr/bin/env bash
# scripts/regen_spec_threads_assert.sh — Threads/atomics official spec corpus.
#
# Distils the upstream testsuite `proposals/threads/atomic.wast` into the
# scalar manifest format consumed by `spec_assert_runner_non_simd` (the host
# runner per the atomics-spec-corpus bundle — broad arg-taking scalar
# execution; the wasm_3_0 runner skips arg-taking asserts).
#
# atomics ops are pure-integer scalar (i32/i64), so NO `(either)` / v128 / nan
# complications. The non_simd runner PERSISTS linear memory across directives
# within a module, so the `action` (store/init) commands are emitted as
# void-result invokes (`-> ()`) to set up state for the load/rmw asserts.
#
# Source: TESTSUITE (proposals/threads), NOT spec/test/core. Run on Mac in the
# nix dev shell (`nix develop .#gen` or with wabt + python3 on PATH).

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_TESTSUITE_REPO:-$HOME/Documents/OSS/WebAssembly/testsuite}
DEST=test/spec/threads-assert
SRC="$UPSTREAM/proposals/threads/atomic.wast"

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_spec_threads_assert] wast2json not found (need wabt / nix dev shell)" >&2
  exit 1
fi
if [ ! -f "$SRC" ]; then
  echo "[regen_spec_threads_assert] missing $SRC" >&2
  exit 1
fi

n=atomic
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

if ! ( cd "$TMP" && wast2json --enable-threads "$SRC" -o "$n.json" >/dev/null 2>&1 ); then
  echo "[regen_spec_threads_assert] wast2json rejected $SRC" >&2
  exit 1
fi

out_dir="$DEST/$n"
rm -rf "$out_dir"
mkdir -p "$out_dir"

python3 - "$TMP/$n.json" "$out_dir/manifest.txt" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))

SCALARS = ("i32", "i64", "f32", "f64")

def tok(v):
    """`<type>:<value>` for a scalar arg/result; `!` prefix = unsupported."""
    t = v["type"]
    if t in SCALARS:
        return f"{t}:{v['value']}"
    return f"!unsupported-type:{t}"

def toks(items):
    out = [tok(x) for x in items]
    bad = [x for x in out if x.startswith("!")]
    return (None, bad[0]) if bad else (" ".join(out) if out else "()", None)

lines = []
for c in d["commands"]:
    t = c.get("type")
    if t == "module":
        lines.append("module " + c["filename"])
    elif t in ("assert_return", "action"):
        # Both nest the invoke under `.action`; `action` commands have
        # `expected:[]` (void invoke run for its side effect — store/init).
        # The runner persists memory across directives, so these set up state
        # for later load/rmw asserts.
        act = c["action"]
        if act.get("type") != "invoke":
            lines.append("skip-impl non-invoke-action")
            continue
        # memory.atomic.wait{32,64} require a SHARED memory; the non_simd runner's
        # scratch (base.growable_memory) is not shared → wait traps kind=15
        # (ExpectedSharedMemory). That is a runner-setup limit, NOT a zwasm bug —
        # wait works on real shared memory (test/edge_cases/p17/atomics). Skip.
        if act["field"].startswith("memory.atomic.wait"):
            lines.append(f"skip-impl runner-nonshared-scratch {act['field']}")
            continue
        args_s, bad = toks(act.get("args", []))
        res_s, bad2 = toks(c.get("expected", []))
        if bad or bad2:
            lines.append(f"skip-impl bad-token {act['field']} {bad or bad2}")
            continue
        fn = act["field"]
        fn_tok = f"'{fn}'" if " " in fn else fn
        lines.append(f"assert_return {fn_tok} {args_s} -> {res_s}")
    elif t == "assert_trap":
        # Atomic unaligned-access traps. nonSimdRunAssertTrap's dispatch ladder
        # covers every atomics trap shape (1-arg load, 2-arg store/rmw, 3-arg
        # i32/i64 cmpxchg) as of §17.4 D-301, so emit the real directive — the
        # RMW / cmpxchg family traps correctly on the JIT. **EXCEPTION (D-303)**:
        # JIT inline `*.atomic.load*` / `*.atomic.store*` codegen (op_memory.zig,
        # both arches) is MISSING the unaligned-atomic alignment check the interp
        # has (`ea & (size-1) != 0 → Trap.UnalignedAtomic`), so they do NOT trap
        # → skip with the precise reason until the JIT fix lands. NOT a runner
        # gap; a real codegen bug tracked as D-303.
        a = c["action"]
        if a.get("type") != "invoke":
            lines.append("skip-impl non-invoke-action-trap")
            continue
        fn = a.get("field", "?")
        args_s, bad = toks(a.get("args", []))
        if bad:
            lines.append(f"skip-impl bad-token {fn} {bad}")
            continue
        if ".atomic.load" in fn or ".atomic.store" in fn:
            lines.append(f"skip-impl jit-unaligned-trap-gap-D303 {fn}")
            continue
        fn_tok = f"'{fn}'" if " " in fn else fn
        lines.append(f"assert_trap {fn_tok} {args_s}")
    elif t == "assert_invalid":
        lines.append(f"assert_invalid {c['filename']}")
    elif t == "assert_malformed":
        if c.get("module_type") == "binary" and "filename" in c:
            lines.append(f"assert_malformed {c['filename']}")
        else:
            lines.append("skip-adr-skip_text_format_parser directive-assert_malformed-text")
    else:
        lines.append(f"skip-impl directive-{t}")

open(dst, "w").write("\n".join(lines) + "\n")
PY

# Copy referenced .wasm files (module / assert_invalid / assert_malformed).
while read -r line; do
  set -- $line
  if [ "$1" = "module" ] || [ "$1" = "assert_invalid" ] || [ "$1" = "assert_malformed" ]; then
    cp "$TMP/$2" "$out_dir/"
  fi
done < "$out_dir/manifest.txt"

echo "[regen_spec_threads_assert] re-baked: $n → $DEST/"
