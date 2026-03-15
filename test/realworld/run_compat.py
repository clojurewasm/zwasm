#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = ROOT / "test" / "realworld"
WASM_DIR = SCRIPT_DIR / "wasm"


def normalize_output(text: str) -> str:
    return re.sub(r"argv\[0\] = .*[\\/]", "argv[0] = ", text)


def run_process(cmd: list[str], cwd: Path | None = None) -> tuple[int, str, str]:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    return result.returncode, result.stdout, result.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare zwasm vs wasmtime on real-world wasm programs.")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    exe_name = "zwasm.exe" if sys.platform == "win32" else "zwasm"
    zwasm = ROOT / "zig-out" / "bin" / exe_name
    if not zwasm.is_file():
        print("Building zwasm...")
        result = subprocess.run(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ROOT, check=False)
        if result.returncode != 0:
            return result.returncode

    wasmtime = shutil.which("wasmtime")
    if wasmtime is None:
        print("wasmtime not found in PATH")
        return 1

    wasm_files = sorted(WASM_DIR.glob("*.wasm"))
    if not wasm_files:
        print("No wasm files found. Run build_all.py first.")
        return 1

    pass_count = fail_count = crash_count = total = 0
    results: list[str] = []

    with tempfile.TemporaryDirectory(prefix="zwasm-realworld-") as tmp:
        tmp_dir = Path(tmp)
        print("=== Compatibility Test: zwasm vs wasmtime ===")
        _, zwasm_version, _ = run_process([str(zwasm), "--version"])
        _, wasmtime_version, _ = run_process([wasmtime, "--version"])
        print(f"zwasm: {zwasm_version.strip() or 'unknown'}")
        print(f"wasmtime: {wasmtime_version.strip() or 'unknown'}")
        print()

        for wasm in wasm_files:
            total += 1
            name = wasm.stem

            extra_args: list[str] = []
            wt_extra: list[str] = []
            zw_extra: list[str] = ["--allow-all"]
            if "hello_wasi" in name or name == "tinygo_hello":
                extra_args = ["arg1", "arg2"]
            if "file_io" in name:
                if sys.platform == "win32":
                    # Windows: map host temp dir to a stable guest path
                    guest_dir = "/sandbox"
                    wt_extra = ["--dir", f"{tmp_dir}::{guest_dir}"]
                    zw_extra += ["--dir", f"{tmp_dir}::{guest_dir}"]
                    extra_args = [f"{guest_dir}/zwasm_test_file_io.txt"]
                else:
                    wt_extra = ["--dir", str(tmp_dir)]
                    zw_extra += ["--dir", str(tmp_dir)]
                    extra_args = [str(tmp_dir / "zwasm_test_file_io.txt")]

            wt_exit, wt_out, wt_err = run_process([wasmtime, "run", *wt_extra, str(wasm), *extra_args])
            zw_exit, zw_out, zw_err = run_process([str(zwasm), "run", *zw_extra, str(wasm), *extra_args])

            wt_norm = normalize_output(wt_out)
            zw_norm = normalize_output(zw_out)

            if zw_exit > 128:
                status = "CRASH"
                crash_count += 1
                results.append(f"  CRASH: {name} (signal {zw_exit - 128})")
            elif wt_norm == zw_norm and wt_exit == zw_exit:
                status = "PASS"
                pass_count += 1
            elif wt_norm == zw_norm:
                status = "EXIT_DIFF"
                fail_count += 1
                results.append(f"  EXIT_DIFF: {name} (wasmtime={wt_exit}, zwasm={zw_exit})")
            else:
                status = "DIFF"
                fail_count += 1
                results.append(f"  DIFF: {name}")
                if args.verbose:
                    print("    wasmtime stdout (normalized):")
                    print("\n".join(wt_norm.splitlines()[:20]))
                    print("    zwasm stdout (normalized):")
                    print("\n".join(zw_norm.splitlines()[:20]))
                    print("    wasmtime stderr:")
                    print("\n".join(wt_err.splitlines()[:20]))
                    print("    zwasm stderr:")
                    print("\n".join(zw_err.splitlines()[:20]))

            print(f"  {status:<9}{name}")

    print()
    print("=== Summary ===")
    print(f"PASS: {pass_count}  FAIL: {fail_count}  CRASH: {crash_count}  TOTAL: {total}")
    if results and fail_count + crash_count > 0:
        print("Details:")
        for line in results:
            print(line)
    return fail_count + crash_count


if __name__ == "__main__":
    sys.exit(main())
