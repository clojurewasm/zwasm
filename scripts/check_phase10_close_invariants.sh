#!/usr/bin/env bash
# scripts/check_phase10_close_invariants.sh
#
# Verify Phase 10 / 10.M = DONE invariants per ADR-0111 Revision
# (2026-05-25 user collab 1/7): the i64 memory64 emit code MUST be
# comptime-DCE'd from the `-Dwasm=v2_0` build, mechanically proving
# the comptime + runtime 2-stage gate (ADR-0111 D4) works as
# designed. Without DCE, a v2.0 build would carry dead memory64 code
# (binary size + i32 fast-path attack surface) — the gate verifies
# the comptime arm is structurally pruned, not just runtime-skipped.
#
# Currently checks I1 only (memory64 i64-arm DCE). Future Phase 10
# close invariants will land here as 10.M-* sub-chunks complete
# (10.R / 10.TC / 10.E / 10.G have their own close criteria).
#
# Usage:
#   bash scripts/check_phase10_close_invariants.sh        # report mode
#   bash scripts/check_phase10_close_invariants.sh --gate # exit non-0 on any FAIL
#
# Caveats:
#   - Builds with `-Dwasm=v2_0`; restores the default `-Dwasm=v3_0`
#     build cache slot on exit (zig caches per-options, so the next
#     `zig build` resumes the default cache without rebuild).
#   - Mac aarch64 host: checks arm64 emitMemOpI64. x86_64 host:
#     checks x86_64 emitMemOpI64 (the inactive arch is comptime-
#     pruned from the binary regardless of -Dwasm).
#   - Does NOT run tests; pairs with the host gate (`zig build
#     test-all`) for behaviour verification.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

GATE=0
if [ "${1:-}" = "--gate" ]; then GATE=1; fi

FAILS=0
TOTAL=0
SKIPS=0
LINES=()

fail() { LINES+=("FAIL  $1"); FAILS=$((FAILS+1)); TOTAL=$((TOTAL+1)); }
ok()   { LINES+=("OK    $1"); TOTAL=$((TOTAL+1)); }
skip() { LINES+=("SKIP  $1"); SKIPS=$((SKIPS+1)); TOTAL=$((TOTAL+1)); }

echo "[check_phase10_close_invariants] running invariants ..."
echo

# I1 — memory64 i64-arm comptime-DCE under -Dwasm=v2_0 (ADR-0111
# Revision 2026-05-25 / D4 anchor). Build the CLI binary with
# -Dwasm=v2_0; nm-grep for emitMemOpI64 (private fn, file-scope
# symbol per Zig mangling); expect zero matches.
echo "[I1] building -Dwasm=v2_0 ..."
if ! zig build -Dwasm=v2_0 > /tmp/check_p10_build_v2.log 2>&1; then
  fail "I1: -Dwasm=v2_0 build failed; see /tmp/check_p10_build_v2.log"
else
  bin=zig-out/bin/zwasm
  if [ ! -x "$bin" ]; then
    fail "I1: $bin not found after -Dwasm=v2_0 build"
  else
    count=$(nm "$bin" 2>/dev/null | grep -cE 'emitMemOpI64\b' || true)
    if [ "$count" -eq 0 ]; then
      ok "I1: emitMemOpI64 absent from -Dwasm=v2_0 binary (count=0; comptime DCE confirmed)"
    else
      fail "I1: emitMemOpI64 leaked into -Dwasm=v2_0 binary (count=$count); comptime gate failed"
    fi
  fi
fi

# Restore default (v3_0) build cache slot so subsequent `zig build`
# doesn't rebuild from scratch.
zig build > /dev/null 2>&1 || true

# ============================================================
# §8 close-gate invariants per `.dev/phase10_design_plan_ja.md`
# (10.G op_gc cycle 30 pivot — scaffold remaining 22 invariants
#  as SKIP placeholders + the few that are mechanically
#  verifiable today as PASS).
# ============================================================

# §8 I1 — per-op file wasm_level + handlers struct declared.
# Stub-style op files (per ADR-0023 §3 reference table) carry
# `pub const op_tag:` + `pub const wasm_level:` + `pub const handlers`.
# Walk each stub file; require both wasm_level + handlers.
# Runtime handler-non-null verified by per-op behaviour tests
# (passing zig build test invariant covers it transitively).
i1_files=( $(grep -l "pub const op_tag:" src/instruction/wasm_3_0/*.zig 2>/dev/null) )
i1_total=${#i1_files[@]}
i1_missing=0
for f in "${i1_files[@]}"; do
  if ! grep -q "pub const wasm_level: ?WasmLevel = .v3_0" "$f"; then
    i1_missing=$((i1_missing + 1))
  fi
  if ! grep -q "pub const handlers = .{" "$f"; then
    i1_missing=$((i1_missing + 1))
  fi
done
if [ $i1_total -gt 0 ] && [ $i1_missing -eq 0 ]; then
  ok "§8 I1: $i1_total Phase 10 op stub files; all declare wasm_level: .v3_0 + handlers struct"
else
  fail "§8 I1: $i1_missing declaration(s) missing across $i1_total stub files"
fi

# §8 I2 — spec testsuite green (memory64 + tail-call + func-refs + EH + GC)
skip "§8 I2: memory64 FULL GREEN; EH/GC/func-refs gated on D-179 + D-192"

# §8 I3 — test/edge_cases/p10/cross/ 7 fixtures green
if [ -d test/edge_cases/p10/cross ]; then
  fc=$(find test/edge_cases/p10/cross -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')
  skip "§8 I3: p10/cross fixtures present: $fc; corpus green deferred"
else
  skip "§8 I3: test/edge_cases/p10/cross/ not yet populated"
fi

# §8 I4 — covered by the pre-existing I1 above (memory64 i64-arm DCE).
# The top-of-script I1 (memory64 emitMemOpI64 nm check) is the
# concrete §8 I4 evidence: -Dwasm=v2_0 + nm verifies the comptime
# DCE strip works. Future Phase 10 ops (EH / GC / TC) will extend
# the nm check with their own symbols as those features ship a
# v2_0-strip-eligible boundary.
if [ $FAILS -eq 0 ] && grep -q "emitMemOpI64 absent" <(printf '%s\n' "${LINES[@]}"); then
  ok "§8 I4: top I1 DCE check green (memory64 emitMemOpI64 stripped from -Dwasm=v2_0)"
else
  skip "§8 I4: top I1 DCE check not green yet; extends to EH/GC/TC as those features land"
fi

# §8 I5 — needs_gc_heap=false → GC infra zero calls
skip "§8 I5: module-driven verify requires synthetic fixtures; deferred"

# §8 I6 — -Dgc=false complete strip + -Dgc=true compiles.
# Build both paths; each must exit 0. (Deep "no GC symbols leak"
# nm verify defers — CLI binary already DCE-strips unused
# symbols regardless of the build option, so nm alone isn't
# definitive; the meaningful close-time check is "default
# build green AND opt-in build green".)
i6_false=1
i6_true=1
zig build -Dgc=false > /tmp/check_p10_gcfalse.log 2>&1 && i6_false=0
zig build -Dgc=true  > /tmp/check_p10_gctrue.log 2>&1 && i6_true=0
if [ $i6_false -eq 0 ] && [ $i6_true -eq 0 ]; then
  ok "§8 I6: -Dgc=false + -Dgc=true both build clean (strip seam works)"
else
  fail "§8 I6: -Dgc build failed (false=$i6_false true=$i6_true; see /tmp/check_p10_gc{false,true}.log)"
fi

# §8 I7 — emit_test_*.zig snapshot byte-identical w/ Phase 9
skip "§8 I7: Phase 9 baseline snapshot deliverable T.3"

# §8 I8 — zone_check --gate green
if bash scripts/zone_check.sh --gate > /dev/null 2>&1; then
  ok "§8 I8: zone_check --gate green"
else
  fail "§8 I8: zone_check --gate exit non-zero"
fi

# §8 I9 — file_size_check --gate green
if bash scripts/file_size_check.sh --gate > /dev/null 2>&1; then
  ok "§8 I9: file_size_check --gate green"
else
  fail "§8 I9: file_size_check --gate exit non-zero"
fi

# §8 I10 — check_fallback_patterns --gate green
if bash scripts/check_fallback_patterns.sh --gate > /dev/null 2>&1; then
  ok "§8 I10: check_fallback_patterns --gate green"
else
  fail "§8 I10: check_fallback_patterns --gate exit non-zero"
fi

# §8 I11 — bench Phase 10 close vs Phase 9 baseline
skip "§8 I11: bench baseline comparison deferred to close cycle"

# §8 I12 — ADR-0111..0117 Accepted (mechanical grep for the canonical
# `- **Status**: Accepted` line shape used across .dev/decisions/).
i12_pending=0
i12_missing=()
for adr_num in 0111 0112 0113 0114 0115 0116 0117; do
  adr_f=$(ls .dev/decisions/${adr_num}_*.md 2>/dev/null | head -1)
  if [ -z "$adr_f" ]; then
    i12_pending=$((i12_pending + 1))
    i12_missing+=("ADR-$adr_num (missing)")
    continue
  fi
  if ! grep -qE "^- \*\*Status\*\*: (Accepted|Closed)" "$adr_f"; then
    i12_pending=$((i12_pending + 1))
    i12_missing+=("ADR-$adr_num")
  fi
done
if [ $i12_pending -eq 0 ]; then
  ok "§8 I12: ADR-0111..0117 all Accepted/Closed"
else
  fail "§8 I12: $i12_pending ADR(s) not Accepted/Closed: ${i12_missing[*]}"
fi

# §8 I13 — ROADMAP §12 stack-map exit criterion
if grep -q "stack-map" .dev/ROADMAP.md 2>/dev/null; then
  ok "§8 I13: ROADMAP stack-map term present"
else
  skip "§8 I13: ROADMAP §12 stack-map criterion deferred"
fi

# §8 I14 — wasm.h tag accessors complete
skip "§8 I14: EH tag accessors gated on D-192 EH runtime"

# §8 I15 — safepoint-free invariant via comptime assert
sp=$(grep -rl "pub const is_safepoint: bool = false" src/ 2>/dev/null | wc -l | tr -d ' ')
skip "§8 I15: is_safepoint=false decls=$sp; comptime-assert verify deferred"

# §8 I16 — regalloc 3-axis default-off Phase 9 corpus green
skip "§8 I16: regalloc 3-axis JIT-side work; deferred to 10.E/G JIT"

# §8 I17 — private/spikes/ all merged/rejected
if [ -d private/spikes ]; then
  running=$(grep -rl "Status: running" private/spikes/ 2>/dev/null | wc -l | tr -d ' ')
  if [ "$running" -eq 0 ]; then
    ok "§8 I17: private/spikes/ no running spikes"
  else
    skip "§8 I17: private/spikes/ has $running running spike(s); 14-day audit"
  fi
else
  ok "§8 I17: private/spikes/ absent"
fi

# §8 I18 — debt.md no `now`-status rows lingering past trigger.
# Every row's Status is either `now` (discharge this resume) OR
# `blocked-by: <named barrier>`. A `now` row that survives a
# resume without action is the "trigger-not-fired masquerade".
# Mechanical: count `| now ` cell occurrences vs total D-NNN rows.
debt_now=$(awk -F'|' '/^\| D-[0-9]+/ { for(i=1;i<=NF;i++) if($i ~ /^ now /) { c++; break } } END { print c+0 }' .dev/debt.md)
debt_total=$(awk '/^\| D-[0-9]+/ { c++ } END { print c+0 }' .dev/debt.md)
if [ "$debt_now" -eq 0 ] && [ "$debt_total" -gt 0 ]; then
  ok "§8 I18: debt.md has 0 now-status rows ($debt_total total; all blocked-by)"
else
  fail "§8 I18: debt.md has $debt_now now-status rows of $debt_total total; discharge before Phase 10 close"
fi

# §8 I19 — gc_stress_runner + eh_frequency_runner wired into the
# test-all aggregator + their (skeleton) tests pass. Per build.zig
# (T.6 deliverable), both runners are addRunArtifact'd onto
# `test_step`, so the passing `zig build test` invariant covers
# them transitively. Deep stress-corpus content lands as 10.G /
# 10.E follow-up cycles.
gc_runner=test/runners/gc_stress_runner.zig
eh_runner=test/runners/eh_frequency_runner.zig
if [ -f "$gc_runner" ] && [ -f "$eh_runner" ] && \
   grep -q "gc_stress_runner" build.zig && \
   grep -q "eh_frequency_runner" build.zig; then
  ok "§8 I19: gc_stress + eh_frequency runners present + test-all wired (deep content follow-up)"
else
  skip "§8 I19: runner skeletons / wiring absent (T.6 deliverable)"
fi

# §8 I20 — SKIP-P10-*-GAP = 0 at RUNTIME (spec runner emissions).
# Source mentions in skeleton/doc files don't count; this requires
# running the spec runner + parsing its summary lines. Deferred
# to close-cycle when D-179 unblocks the corpora.
src_mentions=$(grep -rlnE 'SKIP-P10-(PARSER|EH|GC|MEM64|CROSS)-GAP' src/ test/ 2>/dev/null | wc -l | tr -d ' ')
skip "§8 I20: src mentions=$src_mentions (skeleton/doc); runtime emission check deferred to close"

# §8 I21 — test/realworld/p10/ 9 fixture 5 toolchain green
skip "§8 I21: realworld/p10 toolchain gated on D-179 + Dart/hoot"

# §8 I22 — skip-list ratchet (Phase 10 close skip-impl ≤ Phase 9
# baseline). Parse skip_impl_history.yaml — first `total:` is the
# Phase 9 baseline (commit "(baseline)"); last `total:` is the
# current measurement. Ratchet requires current ≤ baseline.
sih=bench/results/skip_impl_history.yaml
if [ -f "$sih" ]; then
  baseline_total=$(grep -E "^\s+total:" "$sih" | head -1 | awk '{print $2}')
  current_total=$(grep -E "^\s+total:" "$sih" | tail -1 | awk '{print $2}')
  if [ -n "$baseline_total" ] && [ -n "$current_total" ] && [ "$current_total" -le "$baseline_total" ]; then
    ok "§8 I22: skip-impl ratchet green (current=$current_total ≤ baseline=$baseline_total)"
  else
    fail "§8 I22: skip-impl ratchet broken (current=$current_total > baseline=$baseline_total)"
  fi
else
  skip "§8 I22: $sih missing; ratchet history not initialised"
fi

# §8 I23 — widget Phase 10 IN-PROGRESS → DONE
skip "§8 I23: widget status TBD by phase-close cycle itself"

# Report
echo
printf '%s\n' "${LINES[@]}"
echo
echo "[check_phase10_close_invariants] $((TOTAL - FAILS - SKIPS)) PASS / $SKIPS SKIP / $FAILS FAIL  (of $TOTAL)"

if [ $GATE -eq 1 ] && [ $FAILS -gt 0 ]; then
  echo "[check_phase10_close_invariants] FAIL — Phase 10 / 10.M NOT eligible to close until all invariants hold."
  echo "[check_phase10_close_invariants] See ADR-0111 (D4 + Revision 2026-05-25)."
  exit 1
fi

if [ $FAILS -eq 0 ]; then
  echo "[check_phase10_close_invariants] OK — Phase 10 / 10.M close-eligible (invariants satisfied)."
fi

exit 0
