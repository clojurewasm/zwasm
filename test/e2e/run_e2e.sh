#!/bin/bash
# Run zwasm e2e tests (wasmtime misc_testsuite port).
#
# Usage:
#   bash test/e2e/run_e2e.sh [--summary] [--verbose] [--convert] [--batch N]
#
# Options:
#   --summary   Show per-file summary
#   --verbose   Show individual failures
#   --convert   Re-run conversion before testing
#   --batch N   Only convert/run batch N (1-4)

set -e
cd "$(dirname "$0")/../.."

SUMMARY=""
VERBOSE=""
CONVERT=""
BATCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) SUMMARY="--summary"; shift ;;
        --verbose|-v) VERBOSE="--verbose"; shift ;;
        --convert) CONVERT=1; shift ;;
        --batch) BATCH="$2"; shift 2 ;;
        --batch=*) BATCH="${1#--batch=}"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

JSON_DIR="test/e2e/json"

# Convert if requested or json dir is empty
if [ -n "$CONVERT" ] || [ ! "$(ls -A "$JSON_DIR" 2>/dev/null)" ]; then
    echo "Converting e2e test files..."
    if [ -n "$BATCH" ]; then
        bash test/e2e/convert.sh --batch "$BATCH"
    else
        bash test/e2e/convert.sh
    fi
    echo ""
fi

# Check that we have test files
if [ ! "$(ls -A "$JSON_DIR" 2>/dev/null)" ]; then
    echo "ERROR: No JSON test files in $JSON_DIR"
    echo "Run: bash test/e2e/convert.sh"
    exit 1
fi

# Run tests using run_spec.py with --dir
echo "Running e2e tests..."
python3 test/spec/run_spec.py --dir "$JSON_DIR" $SUMMARY $VERBOSE
