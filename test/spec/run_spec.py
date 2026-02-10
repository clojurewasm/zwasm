#!/usr/bin/env python3
"""
zwasm spec test runner.
Reads wast2json output (JSON + .wasm files) and runs assertions via zwasm CLI.

Usage:
    python3 test/spec/run_spec.py [--filter PATTERN] [--verbose] [--summary]
    python3 test/spec/run_spec.py --file test/spec/json/i32.json
"""

import json
import os
import subprocess
import sys
import glob
import math
import struct
import argparse

ZWASM = "./zig-out/bin/zwasm"
SPEC_DIR = "test/spec/json"


def parse_value(val_obj):
    """Parse a JSON value object to u64. Returns ("skip",) for unsupported types."""
    vtype = val_obj["type"]
    vstr = val_obj["value"]

    # v128 (SIMD) values are lists — can't pass via CLI
    if isinstance(vstr, list):
        return ("skip",)

    if vtype == "v128" or vtype == "funcref" or vtype == "externref":
        return ("skip",)

    if vstr.startswith("nan:"):
        return ("nan", vtype)

    v = int(vstr)
    # Ensure unsigned
    if vtype in ("i32", "f32"):
        v = v & 0xFFFFFFFF
    elif vtype in ("i64", "f64"):
        v = v & 0xFFFFFFFFFFFFFFFF
    return v


def is_nan_u64(val, vtype):
    """Check if a u64 value represents NaN for the given type."""
    if vtype == "f32":
        # f32 NaN: exponent bits all 1, fraction != 0
        exp = (val >> 23) & 0xFF
        frac = val & 0x7FFFFF
        return exp == 0xFF and frac != 0
    elif vtype == "f64":
        exp = (val >> 52) & 0x7FF
        frac = val & 0xFFFFFFFFFFFFF
        return exp == 0x7FF and frac != 0
    return False


def run_invoke(wasm_path, func_name, args):
    """Run zwasm --invoke and return (success, results_or_error)."""
    cmd = [ZWASM, "run", "--invoke", func_name, wasm_path]
    for a in args:
        cmd.append(str(a))

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return (False, result.stderr.strip())
        output = result.stdout.strip()
        if not output:
            return (True, [])
        parts = output.split()
        return (True, [int(p) for p in parts])
    except subprocess.TimeoutExpired:
        return (False, "timeout")
    except Exception as e:
        return (False, str(e))


def run_test_file(json_path, verbose=False):
    """Run all commands in a spec test JSON file. Returns (passed, failed, skipped)."""
    with open(json_path) as f:
        data = json.load(f)

    test_dir = os.path.dirname(json_path)
    current_wasm = None
    passed = 0
    failed = 0
    skipped = 0

    for cmd in data.get("commands", []):
        cmd_type = cmd["type"]
        line = cmd.get("line", 0)

        if cmd_type == "module":
            wasm_file = cmd.get("filename")
            if wasm_file:
                current_wasm = os.path.join(test_dir, wasm_file)
            continue

        if cmd_type == "register":
            # Multi-module linking not yet supported in CLI
            skipped += 1
            continue

        if cmd_type == "assert_return":
            if current_wasm is None:
                skipped += 1
                continue

            action = cmd.get("action", {})
            if action.get("type") != "invoke":
                skipped += 1
                continue

            # If action references a named module, skip for now
            if action.get("module"):
                skipped += 1
                continue

            func_name = action["field"]
            args = [parse_value(a) for a in action.get("args", [])]

            # Skip if any arg is NaN (can't pass via CLI)
            if any(isinstance(a, tuple) for a in args):
                skipped += 1
                continue

            expected = [parse_value(e) for e in cmd.get("expected", [])]

            # Skip if any expected value is unsupported (NaN, v128, etc.)
            if any(isinstance(e, tuple) and e[0] == "skip" for e in expected):
                skipped += 1
                continue

            ok, results = run_invoke(current_wasm, func_name, args)

            if not ok:
                if verbose:
                    print(f"  FAIL line {line}: {func_name}({args}) -> error: {results}")
                failed += 1
                continue

            # Compare results
            match = True
            if len(results) != len(expected):
                match = False
            else:
                for r, e in zip(results, expected):
                    if isinstance(e, tuple) and e[0] == "nan":
                        # Expected NaN
                        if not is_nan_u64(r, e[1]):
                            match = False
                    else:
                        # Mask to appropriate width
                        if r != e:
                            match = False

            if match:
                passed += 1
            else:
                if verbose:
                    print(f"  FAIL line {line}: {func_name}({args}) = {results}, expected {expected}")
                failed += 1

        elif cmd_type == "assert_trap":
            if current_wasm is None:
                skipped += 1
                continue

            action = cmd.get("action", {})
            if action.get("type") != "invoke":
                skipped += 1
                continue

            if action.get("module"):
                skipped += 1
                continue

            func_name = action["field"]
            args = [parse_value(a) for a in action.get("args", [])]

            if any(isinstance(a, tuple) for a in args):
                skipped += 1
                continue

            ok, results = run_invoke(current_wasm, func_name, args)

            if not ok:
                # Expected to fail — pass
                passed += 1
            else:
                if verbose:
                    print(f"  FAIL line {line}: {func_name} should have trapped but returned {results}")
                failed += 1

        elif cmd_type in ("assert_invalid", "assert_malformed",
                          "assert_unlinkable", "assert_uninstantiable",
                          "assert_exhaustion"):
            # These test module validation — skip for now, add in task 2.6
            skipped += 1

        elif cmd_type == "action":
            # Bare action (not assertion) — just run it
            skipped += 1

        else:
            skipped += 1

    return (passed, failed, skipped)


def main():
    parser = argparse.ArgumentParser(description="zwasm spec test runner")
    parser.add_argument("--file", help="Run a single test file")
    parser.add_argument("--filter", help="Glob pattern for test names (e.g., 'i32*')")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show individual failures")
    parser.add_argument("--summary", action="store_true", help="Show per-file summary")
    args = parser.parse_args()

    if args.file:
        json_files = [args.file]
    elif args.filter:
        json_files = sorted(glob.glob(os.path.join(SPEC_DIR, f"{args.filter}.json")))
    else:
        json_files = sorted(glob.glob(os.path.join(SPEC_DIR, "*.json")))

    if not json_files:
        print("No test files found")
        return

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    file_results = []

    for jf in json_files:
        name = os.path.basename(jf).replace(".json", "")
        p, f, s = run_test_file(jf, verbose=args.verbose)
        total_passed += p
        total_failed += f
        total_skipped += s

        if args.summary or args.verbose:
            status = "PASS" if f == 0 else "FAIL"
            print(f"  {status} {name}: {p} passed, {f} failed, {s} skipped")

        file_results.append((name, p, f, s))

    total = total_passed + total_failed
    rate = (total_passed / total * 100) if total > 0 else 0

    print(f"\n{'='*60}")
    print(f"Spec test results: {total_passed}/{total} passed ({rate:.1f}%)")
    print(f"  Files: {len(json_files)}")
    print(f"  Passed: {total_passed}")
    print(f"  Failed: {total_failed}")
    print(f"  Skipped: {total_skipped}")
    print(f"{'='*60}")

    # Show top failing files
    failing = [(n, p, f, s) for n, p, f, s in file_results if f > 0]
    if failing:
        failing.sort(key=lambda x: -x[2])
        print(f"\nTop failing files:")
        for name, p, f, s in failing[:15]:
            print(f"  {name}: {f} failures ({p} passed)")

    sys.exit(1 if total_failed > 0 else 0)


if __name__ == "__main__":
    main()
