#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
JSON_DIR = ROOT / "test" / "e2e" / "json"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run zwasm E2E tests.")
    parser.add_argument("--summary", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--convert", action="store_true")
    parser.add_argument("--batch")
    args = parser.parse_args()

    if args.convert or not JSON_DIR.exists() or not any(JSON_DIR.iterdir()):
        print("Converting e2e test files...")
        cmd = [sys.executable, str(ROOT / "test" / "e2e" / "convert.py")]
        if args.batch:
            cmd.extend(["--batch", args.batch])
        result = subprocess.run(cmd, check=False)
        if result.returncode != 0:
            return result.returncode
        print()

    if not JSON_DIR.exists() or not any(JSON_DIR.iterdir()):
        print(f"ERROR: No JSON test files in {JSON_DIR}")
        print(f"Run: {sys.executable} test/e2e/convert.py")
        return 1

    exe_name = "e2e_runner.exe" if sys.platform == "win32" else "e2e_runner"
    runner = ROOT / "zig-out" / "bin" / exe_name
    if not runner.is_file():
        print("Building e2e_runner...")
        result = subprocess.run(
            ["zig", "build", "e2e", "-Doptimize=ReleaseSafe"],
            cwd=ROOT, check=False,
        )
        if result.returncode != 0:
            return result.returncode

    cmd = [str(runner), "--dir", str(JSON_DIR)]
    if args.summary:
        cmd.append("--summary")
    if args.verbose:
        cmd.append("-v")
    print("Running e2e tests...")
    return subprocess.run(cmd, cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
