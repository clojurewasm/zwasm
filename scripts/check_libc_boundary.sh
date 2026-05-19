#!/usr/bin/env bash
# scripts/check_libc_boundary.sh — libc dependency boundary lint.
#
# Greps `src/**/*.zig` + `test/**/*.zig` + `build.zig` for `std.c.*` /
# `@extern("c")` / `pthread_*` / `sigsetjmp` / `siglongjmp` /
# `sys_icache_invalidate` call sites and cross-references each site with
# the 3-tier classification in ADR-0070 (necessary / replaceable /
# convenience).
#
# Behaviour:
#   - Sites in the **necessary** allowlist → OK (silent).
#   - Sites in the **replaceable** set → FAIL with remediation hint
#     suggesting the `std.posix.*` / `std.process.*` equivalent.
#   - Sites not classified → FAIL with "new libc dependency requires
#     ADR amendment per ADR-0070".
#
# Phase 9 completion master plan §3.6 / §7 / ADR-0070 (Accepted).
#
# Modes:
#   --gate    : exit non-zero on any FAIL (pre-commit / pre-push gate)
#   --report  : exit 0; print full inventory (audit_scaffolding §G.5 use)
#   (none)    : same as --report

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,23p' "$0"
  exit 0
fi

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- ADR-0070 classification (keep in sync with the ADR) ----------------

# necessary tokens (any-match on the line)
NECESSARY=(
  "pthread_jit_write_protect_np"
  "sys_icache_invalidate"
  "sigsetjmp"
  "siglongjmp"
  "std.c.mmap"
  "std.c.MAP"
  "std.c.MAP_FAILED"
  "std.c.vm_prot_t"
)

# replaceable: symbol → suggested target (Bash 3 doesn't have assoc on macOS by
# default, but Bash 4+ from nix-shell does; fall back to parallel arrays).
REPLACEABLE_SYMS=(
  "std.c.munmap"
  "std.c.getenv"
  "std.c._exit"
  "std.c.pid_t"
  "std.c.kill"
  "std.c.fork"
  "std.c.alarm"
  "std.c.waitpid"
  "std.c.write"
)
REPLACEABLE_HINTS=(
  "std.posix.munmap"
  "std.process.Environ / std.process.getEnvVarOwned"
  "std.posix.exit"
  "std.posix.pid_t"
  "std.posix.kill"
  "std.posix.fork"
  "std.posix.alarm"
  "std.posix.waitpid"
  "std.posix.write"
)

# convenience: allowed in Debug build only
CONVENIENCE=("std.heap.DebugAllocator")

# --- enumerate call sites ------------------------------------------------

PATTERN='std\.c\.[A-Za-z_]+|@extern\(\.\{[[:space:]]*\.library_name[[:space:]]*=[[:space:]]*"c"|pthread_[A-Za-z_]+|sigsetjmp|siglongjmp|sys_icache_invalidate'

# grep src/ + test/ + build.zig. Exclude comments-only lines (`//`).
RAW=$(grep -rnE "$PATTERN" src/ test/ build.zig 2>/dev/null || true)

# Filter comment-only lines (loose; the file:line:body shape always splits at first 2 colons)
SITES=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  body=$(echo "$line" | cut -d: -f3-)
  trimmed=$(echo "$body" | sed -e 's/^[[:space:]]*//')
  case "$trimmed" in
    //*|\#*) continue ;;
  esac
  SITES+=("$line")
done <<< "$RAW"

fail=0
n_necessary=0
n_replaceable=0
n_convenience=0
n_unclassified=0

REPLACEABLE_OUT=()
UNCLASSIFIED_OUT=()
NECESSARY_OUT=()
CONVENIENCE_OUT=()

# Returns "necessary" / "replaceable:<hint>" / "convenience" / "unclassified"
site_class() {
  local line="$1"
  local sym
  for sym in "${NECESSARY[@]}"; do
    case "$line" in *"$sym"*) echo "necessary"; return ;; esac
  done
  local i=0
  for sym in "${REPLACEABLE_SYMS[@]}"; do
    case "$line" in *"$sym"*) echo "replaceable:${REPLACEABLE_HINTS[$i]}"; return ;; esac
    i=$((i+1))
  done
  for sym in "${CONVENIENCE[@]}"; do
    case "$line" in *"$sym"*) echo "convenience"; return ;; esac
  done
  echo "unclassified"
}

for site in "${SITES[@]}"; do
  c=$(site_class "$site")
  case "$c" in
    necessary)
      n_necessary=$((n_necessary+1))
      NECESSARY_OUT+=("$site")
      ;;
    replaceable:*)
      n_replaceable=$((n_replaceable+1))
      hint="${c#replaceable:}"
      REPLACEABLE_OUT+=("$site  →  use $hint")
      fail=1
      ;;
    convenience)
      n_convenience=$((n_convenience+1))
      CONVENIENCE_OUT+=("$site")
      ;;
    unclassified)
      n_unclassified=$((n_unclassified+1))
      UNCLASSIFIED_OUT+=("$site")
      fail=1
      ;;
  esac
done

# --- emit report --------------------------------------------------------

echo "=== libc boundary check (per ADR-0070) ==="
echo "necessary:     $n_necessary sites"
echo "replaceable:   $n_replaceable sites (should migrate to std.posix.* / std.process.*)"
echo "convenience:   $n_convenience sites"
echo "unclassified:  $n_unclassified sites (NEW — requires ADR amendment)"
echo ""

if [ "${#REPLACEABLE_OUT[@]}" -gt 0 ]; then
  echo "--- replaceable sites (migrate per ADR-0070; sample-migration in §9.12-D) ---"
  for s in "${REPLACEABLE_OUT[@]}"; do echo "  $s"; done
  echo ""
fi

if [ "${#UNCLASSIFIED_OUT[@]}" -gt 0 ]; then
  echo "--- unclassified sites (NEW libc dependency — requires ADR-0070 amendment) ---"
  for s in "${UNCLASSIFIED_OUT[@]}"; do echo "  $s"; done
  echo ""
fi

if [ "$MODE" = "--gate" ] && [ "$fail" -ne 0 ]; then
  echo "[check_libc_boundary] FAIL — replaceable or unclassified libc sites (ADR-0070)"
  exit 1
fi

echo "[check_libc_boundary] OK"
exit 0
