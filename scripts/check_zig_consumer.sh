#!/usr/bin/env bash
# External Zig-consumability guard (§16.5 dogfooding, ADR-0109).
#
# Builds + runs docs/examples/zig_dep/, a standalone package that pulls zwasm
# through a `build.zig.zon` path-dep (`b.dependency("zwasm").module("zwasm")`).
# Proves the public `b.addModule("zwasm", …)` export in build.zig stays
# reachable across the package boundary — the thing docs/examples/zig_host/
# (in-repo private module) cannot prove.
#
# NOT wired into the per-chunk gate: building it pulls the whole repo as a
# dependency and transitively fetches the zlinter dev-dep (D-274), so it is
# a manual / periodic check, like the 3-host gates. Exits non-zero on any
# build/run failure (the consumer exits 2 unless add(2,40)==42).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/docs/examples/zig_dep"
timeout "${CONSUMER_TIMEOUT:-600}" zig build run
echo "[check_zig_consumer] OK — external path-dep consumer built + ran"
