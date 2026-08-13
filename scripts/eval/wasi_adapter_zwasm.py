"""wasi-testsuite runtime adapter for zwasm.

Drop this into a `WebAssembly/wasi-testsuite` checkout as `adapters/zwasm.py`
(or point `-r` straight at this path) to run the OFFICIAL WASI conformance
suite against zwasm. Backs §1.7 / §1.9 of
`.dev/meta_audits/2026-08-14-product-evaluation.md`.

    export ZWASM=/path/to/zig-out/bin/zwasm
    python3 test-runner/wasi_test_runner.py \
        -t tests/rust/testsuite/wasm32-wasip1 \
           tests/c/testsuite/wasm32-wasip1 \
           tests/assemblyscript/testsuite/wasm32-wasip1 \
        -r adapters/zwasm.py

Preview 3 needs a `-Dwasi=p3` build and an explicit opt-in, because the
adapter cannot tell which tier the binary was compiled with:

    export ZWASM_WASI_VERSIONS=wasm32-wasip3
"""

import os
import shlex
import subprocess
from typing import Dict, List, Tuple, Optional

# shlex.split() splits according to shell quoting rules.
ZWASM = shlex.split(os.getenv("ZWASM", "zwasm"), posix=(os.name != "nt"))


def get_name() -> str:
    return "zwasm"


def get_version() -> str:
    # `zwasm --version` prints e.g.
    #   zwasm v2.5.0 (wasm: v3_0, wasi: p2, engine: both)
    result = subprocess.run(ZWASM[0:1] + ["--version"],
                            encoding="UTF-8", capture_output=True,
                            check=True)
    return result.stdout.splitlines()[0].split(" ")[1].lstrip("v")


def get_wasi_versions() -> List[str]:
    # p3 is only reachable from a `-Dwasi=p3` build, so it is opt-in rather
    # than declared unconditionally — otherwise a p2 binary would report
    # every p3 test as a failure instead of a skip.
    return os.getenv("ZWASM_WASI_VERSIONS", "wasm32-wasip1").split(",")


def get_wasi_worlds() -> List[str]:
    # zwasm's CLI has no `serve` subcommand, so `wasi:http/service` tests are
    # unreachable from the CLI and are reported as skipped, not failed.
    return ["wasi:cli/command"]


def compute_argv(test_path: str,
                 args_env_root: Tuple[List[str], Dict[str, str], Optional[str]],
                 proposals: List[str],
                 wasi_world: str,
                 wasi_version: str) -> List[str]:
    del proposals, wasi_world, wasi_version  # zwasm needs no per-test flags

    argv = list(ZWASM)
    args, env, root = args_env_root

    argv += ["run"]

    # Pin the engine. This is load-bearing: the default `auto` lane prefers
    # the JIT, and the JIT fails 4 WASI 0.1 tests the interpreter passes
    # (report §1.7), so an unpinned run does not measure what the README's
    # interpreter-scoped rating claims. Must come after `run`, not before.
    engine = os.getenv("ZWASM_ENGINE")
    if engine:
        argv += ["--engine", engine]

    for k, v in env.items():
        argv += ["--env", f"{k}={v}"]  # noqa: E231

    if root:
        # zwasm spells preopens as `--dir <host>[:<guest>]`; the suite always
        # wants the test's root dir mounted at guest `/`.
        argv += ["--dir", f"{root}:/"]  # noqa: E231

    argv += [test_path]
    argv += args
    return argv
