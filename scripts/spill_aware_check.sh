#!/usr/bin/env bash
# Spill-aware op-handler convention enforcement.
#
# Discharged D-034 across §9.7 / 7.5-spec-assertion-driver-{k..p}
# by hand-threading `gprLoadSpilled` / `gprDefSpilled` /
# `gprStoreSpilled` through every i32 / i64 / convert / memory /
# globals / control / call op handler. The convention is now
# load-bearing: a new handler that calls bare `gpr.resolveGpr` /
# `gpr.resolveFp` will reject spilled vregs at runtime
# (surfacing as `Error.UnsupportedOp` from the reject arm).
#
# This check flags any op-handler file where `gpr.resolveGpr(`
# is called but the same enclosing function does NOT also use
# `gprLoadSpilled` or `gprDefSpilled`. False positives are
# permitted only via the explicit `// SPILL-EXEMPT: <reason>`
# comment on the line above the resolveGpr call.
#
# Modes:
#   bash scripts/spill_aware_check.sh            informational; warn-only
#   bash scripts/spill_aware_check.sh --strict   exit 1 on any violation
#   bash scripts/spill_aware_check.sh --gate     exit 1 if violations exceed BASELINE
#
# Implementation: pure awk single-pass per file. Tracks current
# `pub fn` / `fn` boundaries and per-function presence of
# spill-staging calls; emits violations at end of each function.
#
# Invariants:
#   - Per-arch op-handler files: src/engine/codegen/{arm64,x86_64}/op_*.zig
#     + src/engine/codegen/{arm64,x86_64}/emit.zig
#   - Test files (*_test.zig) and the gpr.zig file itself are exempt.

set -euo pipefail

# 17 = today's surface. Breakdown:
#   - 12 FP-side `resolveFp` calls in op_alu_float / op_convert /
#     bounds_check that await FP-class spill-staging machinery
#     (V-class scratch reservation + encLdrSImm/encStrSImm spill
#     paths). Phase 8 prerequisite.
#   - 3 GPR-side calls in op_control.emitEndIntra (merge MOV at
#     if-else join — uses two operand vregs via short-lived
#     resolveGpr; spill staging would require 3 stage regs).
#   - 2 GPR-side in bounds_check trapping trunc ops (FP src + GPR
#     dst; lifts when FP-spill lands).
#   - 1 in op_const.emitI64Const (cosmetic — 64-bit immediate
#     materialiser; can be migrated trivially; intentionally
#     left as a "first easy chunk" target).
# Baseline ratchets DOWN as those land; the gate forbids new
# bare resolveGpr/Fp introductions.
BASELINE=17
MODE="${1:-info}"

cd "$(dirname "$0")/.."

files=$(find src/engine/codegen/arm64 src/engine/codegen/x86_64 \
    -maxdepth 2 \
    -type f \
    -name '*.zig' \
    ! -name '*_test.zig' \
    ! -name 'gpr.zig' \
    2>/dev/null | sort || true)

violations=0
for f in $files; do
    [ -z "$f" ] && continue
    out=$(awk '
        BEGIN { fn = ""; resolves[0] = 0; spills[0] = 0; nresolves = 0 }
        function flush() {
            if (fn != "" && nresolves > 0 && !has_spill) {
                for (i = 0; i < nresolves; i++) {
                    print FILENAME ":" resolve_line[i] ": bare gpr.resolveGpr/Fp without spill-staging in fn `" fn "`"
                }
            }
            fn = ""
            nresolves = 0
            has_spill = 0
        }
        /^(pub )?fn [A-Za-z_][A-Za-z0-9_]*/ {
            flush()
            match($0, /fn [A-Za-z_][A-Za-z0-9_]*/)
            fn = substr($0, RSTART + 3, RLENGTH - 3)
            prev_was_exempt = 0
            next
        }
        /\/\/ SPILL-EXEMPT:/ { prev_was_exempt = 1; next }
        /gpr\.resolve(Gpr|Fp)\(/ {
            if (!prev_was_exempt && fn != "") {
                resolve_line[nresolves] = NR
                nresolves++
            }
            prev_was_exempt = 0
            next
        }
        /gprLoadSpilled|gprDefSpilled|gprStoreSpilled/ {
            has_spill = 1
            prev_was_exempt = 0
            next
        }
        { prev_was_exempt = 0 }
        END { flush() }
    ' "$f")
    if [ -n "$out" ]; then
        echo "$out" >&2
        violations=$((violations + $(echo "$out" | wc -l | tr -d ' ')))
    fi
done

case "$MODE" in
    --strict)
        if [ "$violations" -gt 0 ]; then
            echo "spill_aware_check: $violations violation(s) — strict mode rejects" >&2
            exit 1
        fi
        ;;
    --gate)
        if [ "$violations" -gt "$BASELINE" ]; then
            echo "spill_aware_check: $violations violations exceeds BASELINE=$BASELINE" >&2
            exit 1
        fi
        ;;
    *)
        echo "spill_aware_check: $violations violation(s) (informational)" >&2
        ;;
esac

exit 0
