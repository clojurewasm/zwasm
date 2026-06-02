#!/usr/bin/env bash
# scripts/check_phase9_close_invariants.sh
#
# Verify Phase 9 = DONE invariants I1-I7 per
# `.claude/rules/phase9_close_invariants.md` + `.dev/phase9_close_master.md` §6.
#
# A fresh /continue session reads this via Resume Step 5d to land on
# the truth: Phase 9 cannot close until the underlying Tier-1 work
# lands (SKIP-WIN64-* arms removed; c_api Wasm-2.0 utilisation tests
# present; Zig facade subset implemented; wast_runtime_runner wired;
# workaround-masquerade debts cleared; ADR-0105/0106 Accepted).
#
# Usage:
#   bash scripts/check_phase9_close_invariants.sh        # report mode
#   bash scripts/check_phase9_close_invariants.sh --gate # exit non-0 on any FAIL

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

GATE=0
if [ "${1:-}" = "--gate" ]; then GATE=1; fi

FAILS=0
TOTAL=0
LINES=()

fail() { LINES+=("FAIL  $1"); FAILS=$((FAILS+1)); TOTAL=$((TOTAL+1)); }
ok()   { LINES+=("OK    $1"); TOTAL=$((TOTAL+1)); }

echo "[check_phase9_close_invariants] running invariants I1-I7 ..."
echo

# I1 — Zero SKIP-WIN64-* token emission in spec runner
runner=test/spec/spec_assert_runner_base.zig
if [ ! -f "$runner" ]; then
  fail "I1: $runner not found"
else
  if grep -qE 'SKIP-WIN64-EXHAUSTION' "$runner"; then
    fail "I1: SKIP-WIN64-EXHAUSTION arm still in $runner (D-162 not closed; ADR-0105 not implemented)"
  else
    ok "I1a: SKIP-WIN64-EXHAUSTION arm removed"
  fi
  if grep -qE 'SKIP-WIN64-CALL-INDIRECT-TRAP' "$runner"; then
    fail "I1: SKIP-WIN64-CALL-INDIRECT-TRAP arm still in $runner (D-163 not closed)"
  else
    ok "I1b: SKIP-WIN64-CALL-INDIRECT-TRAP arm removed"
  fi
  if grep -qE 'SKIP-WIN64-MULTI-RESULT' "$runner"; then
    fail "I1: SKIP-WIN64-MULTI-RESULT arm still in $runner (D-164 not closed; ADR-0106 not implemented)"
  else
    ok "I1c: SKIP-WIN64-MULTI-RESULT arm removed"
  fi
fi

# I2 — c_api Wasm-2.0 utilisation tests present
# Per project idiom: c_api tests live as in-source `test "..."` blocks in
# src/api/instance.zig (zig build test discovers them via core runner).
# Check for the 4 required test block name prefixes.
api_test_file=src/api/instance.zig
if [ ! -f "$api_test_file" ]; then
  fail "I2: $api_test_file not found"
else
  for prefix in \
    'wasm 2.0 reftype c_api round-trip' \
    'wasm 2.0 bulk-traps via c_api' \
    'wasm 2.0 mixed-exports c_api walk' \
    'wasm 2.0 cross-module funcref via wasm_instance_new'; do
    if grep -qF "test \"$prefix" "$api_test_file"; then
      ok "I2: test block '$prefix' present in $api_test_file"
    else
      fail "I2: test block '$prefix' MISSING in $api_test_file (per master plan §5.2)"
    fi
  done
fi

# I3 — Zig facade minimum subset in src/zwasm.zig
zwasm_zig=src/zwasm.zig
if [ ! -f "$zwasm_zig" ]; then
  fail "I3: $zwasm_zig not found"
else
  # ADR-0109 amended I3 (2026-05-25): `Engine` replaces the
  # `Runtime` c_api veneer; Module / Instance / Value retained.
  for sym in 'pub const Engine' 'pub const Module' 'pub const Instance' 'pub const Value'; do
    if grep -qE "^$sym" "$zwasm_zig"; then
      ok "I3: $sym present in src/zwasm.zig"
    else
      fail "I3: $sym MISSING in src/zwasm.zig (ADR-0109 native facade; master plan §5.2)"
    fi
  done
fi
# Zig facade test lives as in-source `test "..."` block in src/zwasm.zig
# (same project idiom as c_api tests — see I2 rationale).
if grep -qF 'test "zwasm facade Wasm 2.0' "$zwasm_zig" 2>/dev/null; then
  ok "I3: Zig facade test block present in src/zwasm.zig"
else
  fail "I3: 'zwasm facade Wasm 2.0' test block MISSING in src/zwasm.zig (per master plan §5.2)"
fi

# I4 — wast_runtime_runner (smoke version) in test-all
# Per Agent 2 finding (master plan §5.2 last bullet) — the smoke step
# exercising `wast_runtime_runner` against `test/runners/fixtures/`
# MUST be wired into test-all. The wasmtime_misc full-corpus step is
# intentionally NOT in test-all (deferred to §9.6 / 6.E investigation
# per build.zig:454 comment); that doesn't count against I4.
if grep -qE 'test_all_step\.dependOn\(&run_wast_runtime_smoke\.step\)' build.zig; then
  ok "I4: wast_runtime_runner smoke step wired into test-all"
else
  fail "I4: wast_runtime_runner smoke step not wired into test-all (master plan §5.2 close)"
fi

# I5 — Zero workaround-masquerade `trigger-not-fired` debts
# Match only Status: cells that legitimize the phrase (i.e. the row's
# blocking barrier IS "trigger-not-fired"). Exclude reframe notes that
# explicitly negate it ("not trigger-not-fired" / "NOT trigger-not-fired").
debt=.dev/debt.yaml
if [ ! -f "$debt" ]; then
  fail "I5: $debt not found"
else
  bad=$(yq -r '.entries[] | select(.status == "blocked-by") | .id + ": " + .description' "$debt" \
    | grep -E 'trigger-not-fired' | grep -vE 'not trigger-not-fired|NOT trigger-not-fired' || true)
  if [ -n "$bad" ]; then
    fail "I5: 'blocked-by … trigger-not-fired' workaround-masquerade still in debt.yaml (per ADR-0104 D3 reframe): $bad"
  else
    ok "I5: no 'trigger-not-fired' workaround-masquerade blocked-by entries in debt.yaml"
  fi
fi

# I6 — ADR-0105 + ADR-0106 Accepted (or later post-impl Closed)
# Both "Accepted" (initial user-flip) and "Closed (implemented)"
# (post-impl canonical pass per §9.12-I Phase C) satisfy the
# invariant intent: design decision is final + no longer Proposed.
for adr in 0105_jit_prologue_stack_probe 0106_multi_result_return_convention; do
  f=".dev/decisions/${adr}.md"
  if [ ! -f "$f" ]; then
    fail "I6: $f missing"
    continue
  fi
  if grep -qE '^- \*\*Status\*\*: (Accepted|Closed)' "$f"; then
    status=$(grep -E '^- \*\*Status\*\*:' "$f" | head -1)
    ok "I6: $(basename "$f" .md) $status"
  else
    status=$(grep -E '^- \*\*Status\*\*:' "$f" | head -1)
    fail "I6: $(basename "$f" .md) NOT Accepted/Closed yet — $status (user collab flip at §9.13 gate per ADR-0104 D1.6)"
  fi
done

# I7 — Master plan ACTIVE + handover points at it
mp=.dev/phase9_close_master.md
if [ ! -f "$mp" ]; then
  fail "I7: $mp not found"
else
  if grep -qE '\*\*Doc-state\*\*: (ACTIVE|ARCHIVED-IN-PLACE)' "$mp"; then
    state=$(grep -oE '\*\*Doc-state\*\*: (ACTIVE|ARCHIVED-IN-PLACE)' "$mp" | head -1 | sed 's/.*: //')
    ok "I7: master plan Doc-state: $state"
  else
    fail "I7: master plan does not declare Doc-state: ACTIVE | ARCHIVED-IN-PLACE"
  fi
fi
ho=.dev/handover.md
if [ -f "$ho" ] && grep -qE 'phase9_close_master\.md' "$ho"; then
  ok "I7: handover.md references master plan"
else
  fail "I7: handover.md does NOT reference phase9_close_master.md (P12 refresh missing)"
fi

# Report
echo
printf '%s\n' "${LINES[@]}"
echo
echo "[check_phase9_close_invariants] $((TOTAL - FAILS)) / $TOTAL passed, $FAILS failed"

if [ $GATE -eq 1 ] && [ $FAILS -gt 0 ]; then
  echo "[check_phase9_close_invariants] FAIL — Phase 9 NOT eligible to close until all invariants hold."
  echo "[check_phase9_close_invariants] See .claude/rules/phase9_close_invariants.md + .dev/phase9_close_master.md §6 + §5."
  exit 1
fi

if [ $FAILS -eq 0 ]; then
  echo "[check_phase9_close_invariants] OK — Phase 9 = DONE eligible (invariants I1-I7 satisfied)."
fi

exit 0
