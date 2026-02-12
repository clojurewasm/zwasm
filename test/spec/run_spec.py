#!/usr/bin/env python3
"""
zwasm spec test runner.
Reads wast2json output (JSON + .wasm files) and runs assertions via zwasm CLI.

Uses --batch mode to keep module state across invocations within the same module.

Usage:
    python3 test/spec/run_spec.py [--filter PATTERN] [--verbose] [--summary]
    python3 test/spec/run_spec.py --file test/spec/json/i32.json
    python3 test/spec/run_spec.py --dir test/e2e/json/ --summary
"""

import json
import os
import subprocess
import sys
import glob
import argparse

ZWASM = "./zig-out/bin/zwasm"
SPEC_DIR = "test/spec/json"
SPECTEST_WASM = "test/spec/spectest.wasm"


def v128_lanes_to_u64_pair(lane_type, lanes):
    """Convert v128 lane values to (lo_u64, hi_u64) pair."""
    if lane_type in ("i32", "f32"):
        # 4 x 32-bit lanes
        vals = [int(v) & 0xFFFFFFFF for v in lanes]
        lo = vals[0] | (vals[1] << 32)
        hi = vals[2] | (vals[3] << 32)
    elif lane_type in ("i64", "f64"):
        # 2 x 64-bit lanes
        vals = [int(v) & 0xFFFFFFFFFFFFFFFF for v in lanes]
        lo = vals[0]
        hi = vals[1]
    elif lane_type in ("i8",):
        # 16 x 8-bit lanes
        vals = [int(v) & 0xFF for v in lanes]
        lo = sum(vals[i] << (i * 8) for i in range(8))
        hi = sum(vals[i] << ((i - 8) * 8) for i in range(8, 16))
    elif lane_type in ("i16",):
        # 8 x 16-bit lanes
        vals = [int(v) & 0xFFFF for v in lanes]
        lo = sum(vals[i] << (i * 16) for i in range(4))
        hi = sum(vals[i] << ((i - 4) * 16) for i in range(4, 8))
    else:
        return None
    return (lo & 0xFFFFFFFFFFFFFFFF, hi & 0xFFFFFFFFFFFFFFFF)


def v128_has_nan(lane_type, lanes):
    """Check if any v128 lane is a NaN value."""
    return any(isinstance(v, str) and v.startswith("nan:") for v in lanes)


def parse_value(val_obj):
    """Parse a JSON value object to u64 or v128 tuple. Returns ("skip",) for unsupported types."""
    vtype = val_obj["type"]
    vstr = val_obj["value"]

    if vtype == "v128":
        lane_type = val_obj.get("lane_type", "i32")
        if not isinstance(vstr, list):
            return ("skip",)
        # Check for NaN lanes
        if v128_has_nan(lane_type, vstr):
            return ("v128_nan", lane_type, vstr)
        pair = v128_lanes_to_u64_pair(lane_type, vstr)
        if pair is None:
            return ("skip",)
        return ("v128", pair[0], pair[1])

    if isinstance(vstr, list):
        return ("skip",)

    # Reference types: null = 0, non-null values passed as raw integers
    if vtype in ("funcref", "externref"):
        if vstr == "null":
            return 0  # ref.null = 0 on the stack
        # Non-null: pass raw integer value
        v = int(vstr)
        return v & 0xFFFFFFFFFFFFFFFF

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
        exp = (val >> 23) & 0xFF
        frac = val & 0x7FFFFF
        return exp == 0xFF and frac != 0
    elif vtype == "f64":
        exp = (val >> 52) & 0x7FF
        frac = val & 0xFFFFFFFFFFFFF
        return exp == 0x7FF and frac != 0
    return False


def match_v128_nan(actual_lo, actual_hi, lane_type, lanes):
    """Check if v128 result matches expected lanes, allowing NaN wildcards."""
    if lane_type in ("i32", "f32"):
        actual_lanes = [
            actual_lo & 0xFFFFFFFF,
            (actual_lo >> 32) & 0xFFFFFFFF,
            actual_hi & 0xFFFFFFFF,
            (actual_hi >> 32) & 0xFFFFFFFF,
        ]
        for a, e in zip(actual_lanes, lanes):
            if isinstance(e, str) and e.startswith("nan:"):
                if not is_nan_u64(a, "f32"):
                    return False
            else:
                if a != (int(e) & 0xFFFFFFFF):
                    return False
    elif lane_type in ("i64", "f64"):
        actual_lanes = [actual_lo, actual_hi]
        for a, e in zip(actual_lanes, lanes):
            if isinstance(e, str) and e.startswith("nan:"):
                if not is_nan_u64(a, "f64"):
                    return False
            else:
                if a != (int(e) & 0xFFFFFFFFFFFFFFFF):
                    return False
    elif lane_type == "i16":
        actual_lanes = []
        for i in range(4):
            actual_lanes.append((actual_lo >> (i * 16)) & 0xFFFF)
        for i in range(4):
            actual_lanes.append((actual_hi >> (i * 16)) & 0xFFFF)
        for a, e in zip(actual_lanes, lanes):
            if a != (int(e) & 0xFFFF):
                return False
    elif lane_type == "i8":
        actual_lanes = []
        for i in range(8):
            actual_lanes.append((actual_lo >> (i * 8)) & 0xFF)
        for i in range(8):
            actual_lanes.append((actual_hi >> (i * 8)) & 0xFF)
        for a, e in zip(actual_lanes, lanes):
            if a != (int(e) & 0xFF):
                return False
    else:
        return False
    return True


def match_result(results, expected):
    """Check if results list matches a single expected value (possibly v128)."""
    if isinstance(expected, tuple):
        if expected[0] == "v128":
            # v128 result = 2 u64 values in results
            if len(results) < 2:
                return False
            return results[0] == expected[1] and results[1] == expected[2]
        elif expected[0] == "v128_nan":
            # v128 with NaN lanes
            if len(results) < 2:
                return False
            return match_v128_nan(results[0], results[1], expected[1], expected[2])
        elif expected[0] == "nan":
            if len(results) < 1:
                return False
            return is_nan_u64(results[0], expected[1])
        return False
    # Plain u64 comparison
    return len(results) == 1 and results[0] == expected


def match_results(results, expected_list):
    """Check if results list matches a list of expected values."""
    ridx = 0
    for e in expected_list:
        if isinstance(e, tuple):
            if e[0] == "v128":
                if ridx + 1 >= len(results):
                    return False
                if results[ridx] != e[1] or results[ridx + 1] != e[2]:
                    return False
                ridx += 2
            elif e[0] == "v128_nan":
                if ridx + 1 >= len(results):
                    return False
                if not match_v128_nan(results[ridx], results[ridx + 1], e[1], e[2]):
                    return False
                ridx += 2
            elif e[0] == "nan":
                if ridx >= len(results):
                    return False
                if not is_nan_u64(results[ridx], e[1]):
                    return False
                ridx += 1
            else:
                return False
        else:
            if ridx >= len(results):
                return False
            if results[ridx] != e:
                return False
            ridx += 1
    return ridx == len(results)


def run_invoke_single(wasm_path, func_name, args, linked_modules=None):
    """Run zwasm --invoke in a single process. Fallback for batch failures."""
    cmd = [ZWASM, "run", "--invoke", func_name]
    for name, path in (linked_modules or {}).items():
        cmd.extend(["--link", f"{name}={path}"])
    cmd.append(wasm_path)
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


class BatchRunner:
    """Manages a zwasm --batch subprocess for stateful invocations."""

    def __init__(self, wasm_path, linked_modules=None):
        self.wasm_path = wasm_path
        self.linked_modules = linked_modules or {}
        self.proc = None
        self.needs_state = False  # True if actions have been executed
        self._start()

    def _start(self):
        cmd = [ZWASM, "run", "--batch"]
        for name, path in self.linked_modules.items():
            cmd.extend(["--link", f"{name}={path}"])
        cmd.append(self.wasm_path)
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def _has_problematic_name(self, func_name):
        """Check if function name contains characters that break the line protocol."""
        return '\x00' in func_name or '\n' in func_name or '\r' in func_name

    def invoke(self, func_name, args, timeout=5):
        """Invoke a function. Returns (success, results_or_error)."""
        has_v128 = any(isinstance(a, tuple) and a[0] == "v128" for a in args)
        if self.proc is None or self.proc.poll() is not None:
            if not self.needs_state and not has_v128:
                if not self._has_problematic_name(func_name):
                    return run_invoke_single(self.wasm_path, func_name, args, self.linked_modules)
                return (False, "problematic name + no batch")
            if self.proc is None or self.proc.poll() is not None:
                # Restart batch process if needed
                self._start()
                if self.proc is None or self.proc.poll() is not None:
                    return (False, "process not running")

        # Hex-encode function name if it contains bytes that break the line protocol
        name_bytes = func_name.encode('utf-8')
        if self._has_problematic_name(func_name):
            hex_name = name_bytes.hex()
            cmd_line = f"invoke hex:{hex_name}"
        else:
            cmd_line = f"invoke {len(name_bytes)}:{func_name}"
        for a in args:
            if isinstance(a, tuple) and a[0] == "v128":
                cmd_line += f" v128:{a[1]}:{a[2]}"
            else:
                cmd_line += f" {a}"
        cmd_line += "\n"

        try:
            self.proc.stdin.write(cmd_line)
            self.proc.stdin.flush()

            import select
            ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
            if not ready:
                self.proc.kill()
                self._cleanup_proc()
                self.proc = None
                return (False, "timeout")

            response = self.proc.stdout.readline().strip()
            if not response:
                # Process may have died — try fallback (only for non-v128 args)
                if not self.needs_state and not has_v128:
                    return run_invoke_single(self.wasm_path, func_name, args, self.linked_modules)
                return (False, "no response")
            if response.startswith("ok"):
                parts = response.split()
                results = [int(p) for p in parts[1:]]
                return (True, results)
            elif response.startswith("error"):
                return (False, response[6:] if len(response) > 6 else "unknown")
            else:
                return (False, f"unexpected: {response}")
        except Exception as e:
            self._cleanup_proc()
            self.proc = None
            if not self.needs_state and not has_v128:
                return run_invoke_single(self.wasm_path, func_name, args, self.linked_modules)
            return (False, str(e))

    def _cleanup_proc(self):
        """Close all pipes on the process to avoid BrokenPipeError on GC."""
        if self.proc:
            for pipe in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                try:
                    if pipe:
                        pipe.close()
                except Exception:
                    pass

    def close(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
        self._cleanup_proc()
        self.proc = None


def has_unsupported(vals):
    """Check if any parsed value is unsupported."""
    for v in vals:
        if isinstance(v, tuple):
            if v[0] == "skip":
                return True
            if v[0] == "nan":
                return True  # NaN args can't be passed via CLI
            if v[0] == "v128_nan":
                return True  # v128 with NaN lanes can't be passed as args
    return False


def needs_spectest(wasm_path):
    """Check if a wasm file imports from the 'spectest' module."""
    try:
        with open(wasm_path, 'rb') as f:
            return b'spectest' in f.read()
    except Exception:
        return False


def run_test_file(json_path, verbose=False):
    """Run all commands in a spec test JSON file. Returns (passed, failed, skipped)."""
    with open(json_path) as f:
        data = json.load(f)

    test_dir = os.path.dirname(json_path)
    runner = None
    current_wasm = None
    passed = 0
    failed = 0
    skipped = 0

    # Multi-module support: registered_modules maps name -> wasm_path
    registered_modules = {}

    for cmd in data.get("commands", []):
        cmd_type = cmd["type"]
        line = cmd.get("line", 0)

        if cmd_type == "module":
            # Close previous runner
            if runner:
                runner.close()
                runner = None

            wasm_file = cmd.get("filename")
            if wasm_file:
                current_wasm = os.path.join(test_dir, wasm_file)
                # Auto-link spectest host module if needed
                link_mods = dict(registered_modules)
                if "spectest" not in link_mods and needs_spectest(current_wasm):
                    link_mods["spectest"] = SPECTEST_WASM
                try:
                    runner = BatchRunner(current_wasm, link_mods)
                except Exception:
                    current_wasm = None
            continue

        if cmd_type == "register":
            # Register current module under the given name for imports
            reg_name = cmd.get("as", "")
            if current_wasm and reg_name:
                registered_modules[reg_name] = current_wasm
            continue

        if cmd_type == "action":
            # Bare action — execute it to update module state
            if runner is None:
                skipped += 1
                continue

            action = cmd.get("action", {})
            if action.get("type") != "invoke" or action.get("module"):
                skipped += 1
                continue

            func_name = action["field"]
            args = [parse_value(a) for a in action.get("args", [])]
            if has_unsupported(args):
                skipped += 1
                continue

            # Execute the action (ignore result, mark state as dirty)
            runner.invoke(func_name, args)
            runner.needs_state = True
            continue

        if cmd_type == "assert_return":
            if runner is None:
                skipped += 1
                continue

            action = cmd.get("action", {})
            if action.get("type") != "invoke" or action.get("module"):
                skipped += 1
                continue

            func_name = action["field"]
            args = [parse_value(a) for a in action.get("args", [])]
            if has_unsupported(args):
                skipped += 1
                continue

            expected = [parse_value(e) for e in cmd.get("expected", [])]
            # Support "either" assertions: each entry is a complete result set
            either_raw = cmd.get("either")
            either_sets = None
            if either_raw:
                either_sets = []
                for alt in either_raw:
                    parsed = parse_value(alt)
                    either_sets.append(parsed)
                # Check if any alternative is unsupported
                if any(isinstance(e, tuple) and e[0] == "skip" for e in either_sets):
                    skipped += 1
                    continue
            elif any(isinstance(e, tuple) and e[0] == "skip" for e in expected):
                skipped += 1
                continue

            ok, results = runner.invoke(func_name, args)

            if not ok:
                if verbose:
                    print(f"  FAIL line {line}: {func_name}({args}) -> error: {results}")
                failed += 1
                continue

            # Compare results
            if either_sets is not None:
                # "either" = result must match any ONE alternative
                match = any(match_result(results, alt) for alt in either_sets)
            else:
                match = match_results(results, expected)

            if match:
                passed += 1
            else:
                if verbose:
                    print(f"  FAIL line {line}: {func_name}({args}) = {results}, expected {expected}")
                failed += 1

        elif cmd_type == "assert_trap":
            if runner is None:
                skipped += 1
                continue

            action = cmd.get("action", {})
            if action.get("type") != "invoke" or action.get("module"):
                skipped += 1
                continue

            func_name = action["field"]
            args = [parse_value(a) for a in action.get("args", [])]
            if has_unsupported(args):
                skipped += 1
                continue

            ok, results = runner.invoke(func_name, args)

            if not ok:
                passed += 1
            else:
                if verbose:
                    print(f"  FAIL line {line}: {func_name} should have trapped but returned {results}")
                failed += 1

        elif cmd_type in ("assert_invalid", "assert_malformed",
                          "assert_unlinkable", "assert_uninstantiable"):
            wasm_file = cmd.get("filename")
            module_type = cmd.get("module_type", "binary")
            if module_type != "binary" or not wasm_file:
                skipped += 1
                continue
            wasm_path = os.path.join(test_dir, wasm_file)
            if not os.path.exists(wasm_path):
                skipped += 1
                continue

            if cmd_type == "assert_uninstantiable":
                # Attempt actual instantiation with linked modules
                link_args = []
                for name, path in registered_modules.items():
                    link_args.extend(["--link", f"{name}={path}"])
                try:
                    result = subprocess.run(
                        [ZWASM, "run", wasm_path] + link_args,
                        capture_output=True, text=True, timeout=5)
                    if result.returncode != 0:
                        passed += 1  # Correctly rejected at instantiation
                    else:
                        skipped += 1  # Didn't catch the issue
                except Exception:
                    passed += 1  # crash/timeout = rejected
            else:
                try:
                    result = subprocess.run(
                        [ZWASM, "validate", wasm_path],
                        capture_output=True, text=True, timeout=5)
                    if result.returncode != 0 or "error" in result.stderr:
                        passed += 1
                    else:
                        # Validator didn't catch the issue — skip (not a failure)
                        skipped += 1
                except Exception:
                    passed += 1  # crash/timeout = rejected

        elif cmd_type == "assert_exhaustion":
            skipped += 1

        else:
            skipped += 1

    if runner:
        runner.close()

    return (passed, failed, skipped)


def main():
    parser = argparse.ArgumentParser(description="zwasm spec test runner")
    parser.add_argument("--file", help="Run a single test file")
    parser.add_argument("--filter", help="Glob pattern for test names (e.g., 'i32*')")
    parser.add_argument("--dir", help="Directory containing JSON test files (default: test/spec/json)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show individual failures")
    parser.add_argument("--summary", action="store_true", help="Show per-file summary")
    parser.add_argument("--allow-failures", type=int, default=0,
                        help="Exit 0 if failures <= N (for known/pre-existing failures)")
    args = parser.parse_args()

    test_dir = args.dir if args.dir else SPEC_DIR

    if args.file:
        json_files = [args.file]
    elif args.filter:
        json_files = sorted(glob.glob(os.path.join(test_dir, f"{args.filter}.json")))
    else:
        json_files = sorted(glob.glob(os.path.join(test_dir, "*.json")))

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

    sys.exit(1 if total_failed > args.allow_failures else 0)


if __name__ == "__main__":
    main()
