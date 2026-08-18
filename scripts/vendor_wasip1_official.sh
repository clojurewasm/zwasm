#!/usr/bin/env bash
# Vendor the official wasi-testsuite wasm32-wasip1 conformance binaries into
# test/wasi/wasip1_official/.
#
# Source of truth: the `prod/testsuite-base` branch of
# https://github.com/WebAssembly/wasi-testsuite — the upstream-built binaries
# under tests/{rust,c,assemblyscript}/testsuite/wasm32-wasip1/ (Apache-2.0; see
# legal/THIRD_PARTY.md). Binaries are `wasm-tools strip`ped before committing:
# the raw corpus is 96.5 MiB of which ~94 MiB is Rust debug custom sections;
# stripped it is 5.5 MiB, behavior-identical. (For scale, the already-vendored
# wasip3 corpus is 17 MiB.)
#
# Layout is preserved per source language because upstream ships one
# `manifest.json` suite descriptor per language and the runner reports
# per-suite counts the same way the official python runner does. Test names do
# not collide across the three languages, but the split is kept anyway so a
# diff against upstream stays readable.
#
# Sibling of scripts/vendor_wasip3_official.sh; same deliberate-bump-only rule
# (edit PIN_SHA + re-run + commit). A bump that changes the test count fails
# loudly below rather than silently widening or narrowing the corpus.
set -euo pipefail

PIN_SHA="52aa5d73cb06eab3461d0939eae43423fe49c0b5" # prod/testsuite-base 2026-08-13
CLONE="${WASI_TESTSUITE_CLONE:-$HOME/Documents/OSS/wasi-testsuite}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/wasi/wasip1_official"

# Upstream test count at PIN_SHA, per language. A mismatch means upstream added
# or removed tests: re-read the diff, update these, and re-run. Never let the
# count drift silently (ADR-0174 no-silent-skip).
#
# `<lang>:<count>` pairs rather than an associative array: macOS ships bash 3.2
# (Apple stopped at the last GPL2 release), which has no `declare -A`, and the
# maintainer host is macOS. vendor_wasip3_official.sh is 3.2-clean; this stays
# 3.2-clean too rather than depending on whichever bash happens to be first on
# PATH.
EXPECT="rust:46 c:14 assemblyscript:12"

expected_for() { # $1 = lang -> prints the count, or exits if the lang is unknown
    for pair in $EXPECT; do
        [ "${pair%%:*}" = "$1" ] && { echo "${pair##*:}"; return 0; }
    done
    echo "no EXPECT entry for '$1'" >&2
    exit 1
}

command -v wasm-tools >/dev/null || { echo "wasm-tools required" >&2; exit 1; }
git -C "$CLONE" rev-parse --quiet --verify "$PIN_SHA^{commit}" >/dev/null || {
    echo "pin $PIN_SHA not present in $CLONE — fetch prod/testsuite-base first:" >&2
    echo "  git -C $CLONE fetch origin prod/testsuite-base" >&2
    exit 1
}

# `rm -rf` on a $0-derived path needs a guard: run this script from a copy
# outside the repo and `$(dirname $0)/..` resolves somewhere else entirely
# (observed: `//test/wasi/wasip1_official` when run from /tmp). Refuse unless
# the parent really is this repo. The wipe itself is deliberate — the corpus
# is replaced wholesale on a bump, so a test upstream DELETED must disappear
# here rather than linger as a file nothing regenerates.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$repo_root/build.zig.zon" ] && [ -d "$repo_root/scripts" ] || {
    echo "refusing to wipe '$DEST': '$repo_root' is not the zwasm repo root" >&2
    echo "run this script from its checked-in location (scripts/)" >&2
    exit 1
}

# Count BEFORE wiping. Validating after the copy would delete a known-good
# corpus, write the new one, and only then refuse — leaving the tree holding a
# corpus the script itself just rejected. Reviewing the upstream change is
# `git diff` against the committed corpus, which needs that corpus intact.
for lang in rust c assemblyscript; do
    want="$(expected_for "$lang")"
    have="$(git -C "$CLONE" ls-tree -r --name-only "$PIN_SHA" \
        "tests/$lang/testsuite/wasm32-wasip1/" | grep -c '\.wasm$' || true)"
    [ "$have" -eq "$want" ] || {
        echo "FAIL: $lang has $have tests at $PIN_SHA, expected $want." >&2
        echo "      Upstream changed the corpus. Nothing was written — review the" >&2
        echo "      upstream diff, then update EXPECT and re-run." >&2
        exit 1
    }
done

rm -rf "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

total=0
for lang in rust c assemblyscript; do
    src="tests/$lang/testsuite/wasm32-wasip1"
    out="$DEST/$lang"
    mkdir -p "$out"

    n=0
    for path in $(git -C "$CLONE" ls-tree -r --name-only "$PIN_SHA" "$src/" | grep '\.wasm$'); do
        name="$(basename "$path" .wasm)"
        git -C "$CLONE" show "$PIN_SHA:$path" > "$tmp/in.wasm"
        wasm-tools strip "$tmp/in.wasm" -o "$out/$name.wasm"
        # Manifest is optional upstream: absent = run with no args/env/preopen
        # and expect exit 0.
        if git -C "$CLONE" cat-file -e "$PIN_SHA:$src/$name.json" 2>/dev/null; then
            git -C "$CLONE" show "$PIN_SHA:$src/$name.json" > "$out/$name.json"
        fi
        n=$((n + 1))
    done

    # Suite descriptor (name + wasi version), used verbatim in the run report.
    git -C "$CLONE" show "$PIN_SHA:$src/manifest.json" > "$out/manifest.json"

    # The filesystem tests' preopen root (manifest "root": "fs-tests.dir").
    # NOT flat: the C suite ships `fopendir.dir/file-{0,1}` and `writeable/`,
    # and flattening them with basename silently breaks fdopendir-with-access
    # and the pwrite-* tests. Reproduce the tree verbatim.
    #
    # Tests MUTATE this tree (they create and unlink files in it), so the
    # runner must copy it to a temp dir per test and never point a preopen at
    # the committed copy.
    for f in $(git -C "$CLONE" ls-tree -r --name-only "$PIN_SHA" "$src/fs-tests.dir/"); do
        rel="${f#"$src/"}"
        mkdir -p "$out/$(dirname "$rel")"
        git -C "$CLONE" show "$PIN_SHA:$f" > "$out/$rel"
    done

    # A suite whose manifests name a preopen root must have vendored that tree.
    # Upstream keeps rust's otherwise-empty tree alive with a `.keep` placeholder
    # and git cannot commit an empty directory, so a pin bump that drops the
    # placeholder would vendor a suite where every root-using test cannot run,
    # with nothing recording why. Fail the regen rather than commit that.
    if grep -l '"root"' "$out"/*.json >/dev/null 2>&1 && [ ! -d "$out/fs-tests.dir" ]; then
        echo "ERROR: $lang manifests name a preopen root but no fs-tests.dir was" >&2
        echo "       vendored at $PIN_SHA — upstream moved or dropped the tree." >&2
        exit 1
    fi

    # Belt-and-braces against the pre-flight and the copy loop disagreeing —
    # they enumerate the same tree the same way, so a mismatch here would mean
    # the tree changed underfoot mid-run.
    [ "$n" -eq "$(expected_for "$lang")" ] || {
        echo "FAIL: $lang copied $n tests, pre-flight counted $(expected_for "$lang")." >&2
        echo "      The clone changed during the run. Re-run." >&2
        exit 1
    }
    echo "[vendor_wasip1] $lang: $n tests"
    total=$((total + n))
done

echo "[vendor_wasip1] vendored $total tests at pin $PIN_SHA into $DEST"
echo "[vendor_wasip1] size: $(du -sh "$DEST" | cut -f1)"
