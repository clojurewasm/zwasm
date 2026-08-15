#!/usr/bin/env bash
# check_spec_manifest_shape.sh — pin the property that makes the spec
# runners' enumeration denominator re-derivable by a third party.
#
# ADR-0210: the wasm-3.0 runner prints `lines=<N>`, the count of manifest
# lines it read, and asserts that every one of them lands in exactly one
# accounting bucket. That number is only checkable from outside the
# runner if the corpus is strictly one directive per line — no blank
# lines, no comments, no continuations, no leading indentation. Then:
#
#   cat test/spec/wasm-3.0-assert/*/*/manifest.txt | wc -l
#
# must equal the printed `lines`. This script fails if the corpus ever
# stops having that shape (a regen introducing comments or blank lines
# would silently break the re-derivation while both sides stayed green).
#
# Usage: check_spec_manifest_shape.sh [--gate]
#   (default) report; --gate exits non-zero on any violation.
set -euo pipefail

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CORPORA=(
  "test/spec/wasm-3.0-assert"
)

violations=0
total_lines=0

for corpus in "${CORPORA[@]}"; do
  if [ ! -d "$corpus" ]; then
    echo "MISSING  $corpus (corpus roots are committed; a missing root is a real error)"
    violations=$((violations + 1))
    continue
  fi

  # `while read` rather than `mapfile`: this runs in ci_gate's core leg on
  # all three OSes, and `mapfile` is a bash 4 builtin while macOS's system
  # bash is 3.2 — a `command not found` under `set -euo pipefail` would fail
  # the macOS leg only.
  manifest_count=0
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    manifest_count=$((manifest_count + 1))
    # Blank / whitespace-only lines: would make `wc -l` overcount vs the
    # runner, which skips them before tallying.
    n_blank=$(grep -cE '^[[:space:]]*$' "$m" || true)
    # Comment lines: no directive, but `wc -l` would count them.
    n_comment=$(grep -cE '^[[:space:]]*[#;]' "$m" || true)
    # Leading indentation: the runner trims, but an indented line is a
    # sign of a continuation-style format the line count cannot model.
    n_indent=$(grep -cE '^[[:space:]]+[^[:space:]]' "$m" || true)
    # A final line without a trailing newline makes `wc -l` undercount.
    n_noeol=0
    if [ -s "$m" ] && [ "$(tail -c 1 "$m" | wc -l)" -eq 0 ]; then n_noeol=1; fi
    # A manifest with no directives at all. Not caught by any check above
    # (the `-s` guard skips the newline test and `wc -l` adds 0), and not
    # caught by the runner either: it reads fine, contributes zero lines,
    # and the identity still closes. It nevertheless increments
    # `manifests=`, so the runner would report a sub-corpus that tests
    # nothing as one of its 86 — a denominator backed by no directives.
    n_empty=0
    if [ "$(wc -l < "$m")" -eq 0 ]; then n_empty=1; fi

    if [ "$n_blank" -ne 0 ] || [ "$n_comment" -ne 0 ] || [ "$n_indent" -ne 0 ] || [ "$n_noeol" -ne 0 ] || [ "$n_empty" -ne 0 ]; then
      echo "SHAPE    $m  blank=$n_blank comment=$n_comment indented=$n_indent missing-final-newline=$n_noeol empty=$n_empty"
      violations=$((violations + 1))
    fi
    total_lines=$((total_lines + $(wc -l < "$m")))
    # Depth pinned to the shape the runner actually reads:
    # `<corpus>/<proposal>/<subdir>/manifest.txt`, and never under `raw/`.
    # An unrestricted `find` would count lines from a manifest nested one
    # level deeper — which the runner would not read — so the guard's
    # `lines:` and the runner's `lines=` would silently diverge, and the
    # re-derivation this guard exists to pin would stop holding with
    # nothing comparing the two numbers.
  done < <(find "$corpus" -mindepth 3 -maxdepth 3 -name manifest.txt -not -path '*/raw/*' | sort)

  if [ "$manifest_count" -eq 0 ]; then
    echo "EMPTY    $corpus (no manifest.txt found)"
    violations=$((violations + 1))
  fi

  # The depth pin above keeps the guard counting exactly what the runner
  # reads — but that cuts both ways: a manifest at any OTHER depth is read
  # by neither, so the corpus could grow directives that both numbers
  # ignore and the two would still agree at a stale total. Flag any that
  # the pinned shape excludes. (`raw/` is excluded on purpose: the runner
  # skips it by name.)
  # Depth is measured on the path, not with -mindepth/-maxdepth: those are
  # global traversal options in find, so combining them with -o does NOT
  # express "shallower than 3 OR deeper than 3" and silently matches nothing.
  while IFS= read -r stray; do
    [ -z "$stray" ] && continue
    rel="${stray#"$corpus"/}"
    depth=$(printf '%s' "$rel" | tr -cd '/' | wc -c)
    # <proposal>/<subdir>/manifest.txt == 2 separators. Anything else is
    # outside the shape the runner walks.
    [ "$depth" -eq 2 ] && continue
    echo "UNREAD   $stray  (outside <proposal>/<subdir>/manifest.txt — the runner never reads it, so its directives are in no tally)"
    violations=$((violations + 1))
  done < <(find "$corpus" -name manifest.txt -not -path '*/raw/*' | sort)
done

echo "=== spec manifest shape check ==="
echo "corpora:    ${#CORPORA[@]}"
echo "lines:      $total_lines  (must equal the runner's printed \`lines=\`)"
echo "violations: $violations"

if [ "$MODE" = "--gate" ] && [ "$violations" -gt 0 ]; then
  echo ""
  echo "FAIL: the corpus is no longer one-directive-per-line, so the runner's"
  echo "      enumeration denominator can no longer be re-derived with wc -l."
  exit 1
fi
