#!/usr/bin/env bash
# blocked-by staleness ladder (audit_scaffolding §F.2a; promised by the
# 2026-05-21 blocked-by sweep, delivered by the 2026-08 S5 mechanization).
#
# Every `status: "blocked-by"`-class row in .dev/debt.yaml carries a
# `last_reviewed` date; a barrier nobody has re-walked in >30 days is being
# TRUSTED silently, which is how dissolved barriers (a closed campaign
# removing the blocker) go unnoticed. Ladder: >14d WARN, >30d STALE.
#
# Modes:
#   bash scripts/audit_blocked_by_age.sh          informational (always 0)
#   bash scripts/audit_blocked_by_age.sh --gate   exit 1 when any row is STALE

set -euo pipefail
MODE="${1:-info}"
cd "$(dirname "$0")/.."

python3 - "$MODE" <<'PYEOF'
import re, sys, datetime

mode = sys.argv[1]
text = open('.dev/debt.yaml').read()
today = datetime.date.today()
warn = stale = 0
# rows are "- id:" blocks; a blocked-by row declares status: "blocked-by"
for m in re.finditer(r'- id: "(D-\d+)"(.*?)(?=\n  - id: |\Z)', text, re.S):
    rid, body = m.group(1), m.group(2)
    if '"blocked-by"' not in body:
        continue
    lr = re.search(r'last_reviewed: "(\d{4}-\d{2}-\d{2})"', body)
    if not lr:
        print(f'STALE: {rid} — blocked-by row has NO last_reviewed date', file=sys.stderr)
        stale += 1
        continue
    age = (today - datetime.date.fromisoformat(lr.group(1))).days
    if age > 30:
        print(f'STALE: {rid} — blocked-by barrier last reviewed {age}d ago ({lr.group(1)}); re-walk it', file=sys.stderr)
        stale += 1
    elif age > 14:
        print(f'WARN: {rid} — blocked-by barrier last reviewed {age}d ago', file=sys.stderr)
        warn += 1

if stale or warn:
    print(f'[audit_blocked_by_age] {stale} stale / {warn} aging blocked-by row(s)', file=sys.stderr)
else:
    print('[audit_blocked_by_age] OK — all blocked-by barriers recently reviewed', file=sys.stderr)
sys.exit(1 if (mode == '--gate' and stale) else 0)
PYEOF
