#!/usr/bin/env python3
"""
zwasm spec test runner.
Reads wast2json output (JSON + .wasm files) and runs assertions via zwasm CLI.

Uses --batch mode to keep module state across invocations within the same module.

Usage:
    python3 test/spec/run_spec.py [--filter PATTERN] [--verbose] [--summary]
    python3 test/spec/run_spec.py --file test/spec/json/i32.json
"""

import json
import os
import subprocess
import sys
import glob
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

    if vtype in ("v128", "funcref", "externref"):
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
        exp = (val >> 23) & 0xFF
        frac = val & 0x7FFFFF
        return exp == 0xFF and frac != 0
    elif vtype == "f64":
        exp = (val >> 52) & 0x7FF
        frac = val & 0xFFFFFFFFFFFFF
        return exp == 0x7FF and frac != 0
    return False


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
        return '\n' in func_name or '\r' in func_name

    def invoke(self, func_name, args, timeout=5):
        """Invoke a function. Returns (success, results_or_error)."""
        # Fall back to single-process if name has newlines or batch is dead
        if self._has_problematic_name(func_name):
            if self.needs_state:
                return (False, "stateful+problematic name")
            return run_invoke_single(self.wasm_path, func_name, args, self.linked_modules)

        if self.proc is None or self.proc.poll() is not None:
            if not self.needs_state:
                return run_invoke_single(self.wasm_path, func_name, args, self.linked_modules)
            return (False, "process not running")

        # Length-prefixed function name to handle special characters
        name_bytes = func_name.encode('utf-8')
        cmd_line = f"invoke {len(name_bytes)}:{func_name}"
        for a in args:
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
                # Process may have died — try fallback
                if not self.needs_state:
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
            if not self.needs_state:
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
    """Check if any parsed value is unsupported (skip tuple or NaN)."""
    return any(isinstance(v, tuple) for v in vals)


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
                try:
                    runner = BatchRunner(current_wasm, registered_modules)
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
            if any(isinstance(e, tuple) and e[0] == "skip" for e in expected):
                skipped += 1
                continue

            ok, results = runner.invoke(func_name, args)

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
                        if not is_nan_u64(r, e[1]):
                            match = False
                    else:
                        if r != e:
                            match = False

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
                          "assert_unlinkable", "assert_uninstantiable",
                          "assert_exhaustion"):
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
