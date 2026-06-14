#!/usr/bin/env bash
# check_releasesafe_runners.sh — guard the ADR-0177 ReleaseSafe-runner floor.
#
# A plain `zig build test-all` (Debug default) must run every HEAVY e2e/corpus
# runner ReleaseSafe (~100× faster; cf. ClojureWasmFromScratch's campaign +
# lesson `releasesafe-runner-floor-audit`). The floor is the `core_rs` /
# `zwasm_lib_mod` (= core_rs) / `core_releasesafe` modules + any module on
# `.optimize = runner_optimize`. This check fails when:
#   (a) a NEW module imports the Debug `core` module as "zwasm" outside the
#       justified allowlist (a new runner that forgot the floor), OR
#   (b) `core_comp` (the Component Model spec runner's module, 158-manifest
#       corpus in test-all) regresses from `runner_optimize` back to raw
#       `optimize` (= Debug) — the 2026-06-14 gap.
#
# Debug-by-design allowlist (verified intentional): `core` itself (self-import),
# `core_tests`/`exe` (leak-detecting DebugAllocator + production CLI honours
# -Doptimize), the light unit-test mods, the trivial single-wasm examples.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD=build.zig
fail=0

# (a) Modules importing the Debug `core` module (exact `core`, not core_rs /
#     core_comp / core_releasesafe). Allowlist = Debug-by-design consumers.
allow='^(core|exe_mod|spec_assert_base_test_mod|wasm_3_0_assert_unit_mod|wasm_3_0_manifest_unit_mod|zig_host_mod)$'
while IFS= read -r mod; do
  if ! [[ "$mod" =~ $allow ]]; then
    echo "[check_releasesafe_runners] BLOCK — '$mod' imports the Debug \`core\` module as zwasm."
    echo "  A runner on Debug core runs its corpus ~100× slower in test-all (ADR-0177)."
    echo "  Fix: import \`zwasm_lib_mod\` (= core_rs) instead, OR — if genuinely Debug-by-design"
    echo "  (unit test / production exe / trivial example) — add it to the allowlist here with a reason."
    fail=1
  fi
done < <(grep -oE '[a-z_0-9]+\.addImport\("zwasm", core\)' "$BUILD" | sed -E 's/\.addImport.*//')

# (b) core_comp must stay floored at runner_optimize (the 2026-06-14 fix).
#     Inspect the `const core_comp = b.createModule({...})` block.
core_comp_block=$(awk '/const core_comp = b\.createModule/{f=1} f{print} /\}\);/{if(f) exit}' "$BUILD")
if ! grep -qE '\.optimize = runner_optimize' <<<"$core_comp_block"; then
  echo "[check_releasesafe_runners] BLOCK — core_comp is not on \`.optimize = runner_optimize\`."
  echo "  The Component Model spec runner (158-manifest corpus in test-all) would run Debug."
  echo "  Fix: \`.optimize = runner_optimize\` (ADR-0177 Revision 2026-06-14)."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "[check_releasesafe_runners] OK — all e2e runners ReleaseSafe-floored; core_comp floored."
fi
exit "$fail"
