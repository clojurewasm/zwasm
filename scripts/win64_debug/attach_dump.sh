#!/usr/bin/env bash
# attach_dump.sh — run zwasm-spec-wasm-2-0-assert on windowsmini against
# a manifest dir, attach lldb after N seconds, dump register + backtrace
# + selected memory, detach, kill. Output collected to /tmp/d165-attach.log.
#
# Usage:
#   bash scripts/win64_debug/attach_dump.sh <local-manifest-dir> [wait-sec]
#
# Pre-req: windowsmini SSH alias set up per .dev/windows_ssh_setup.md.
# scratch dir at test/private/d-165/ used on both sides.

set -euo pipefail

LOCAL_DIR="${1:-test/private/d-165}"
WAIT_SEC="${2:-3}"
REMOTE_DIR="Documents/MyProducts/zwasm_from_scratch/test/private/d-165"
LOG="/tmp/d165-attach.log"

if [ ! -d "$LOCAL_DIR/fac" ]; then
  echo "missing $LOCAL_DIR/fac/" >&2
  exit 2
fi

# Sync the manifest dir contents to windowsmini.
scp -q -r "$LOCAL_DIR/fac/" "windowsmini:$REMOTE_DIR/" >&2

# Build a remote bash script (single-quoted heredoc so $vars resolve on remote).
# 1. Find newest runner exe
# 2. Start it in background against the manifest
# 3. Sleep WAIT_SEC
# 4. tasklist → Win-native PID
# 5. lldb -b -p WPID with dump commands
# 6. taskkill
ssh windowsmini bash -lc "'
  set +e
  cd ~/Documents/MyProducts/zwasm_from_scratch
  EXE=\$(ls -t .zig-cache/o/*/zwasm-spec-wasm-2-0-assert.exe | head -1)
  echo === Runner: \$EXE ===
  rm -f /tmp/d165-run.log
  \"\$EXE\" test/private/d-165 > /tmp/d165-run.log 2>&1 &
  RPID=\$!
  sleep $WAIT_SEC
  WPID=\$(tasklist /FI \"IMAGENAME eq zwasm-spec-wasm-2-0-assert.exe\" /NH /FO CSV 2>/dev/null | head -1 | awk -F, \"{ gsub(/[\\\"\\\\s]/,\\\"\\\",\\\$2); print \\\$2 }\")
  echo === bash-PID=\$RPID  win-PID=\$WPID ===
  if [ -z \"\$WPID\" ]; then
    echo runner already exited or PID lookup failed
    cat /tmp/d165-run.log
    exit 1
  fi
  echo === lldb -b attach ===
  /c/Program\\ Files/LLVM/bin/lldb -b -p \$WPID \
    -o \"process interrupt\" \
    -o \"settings set target.x86-disassembly-flavor intel\" \
    -o \"register read rax rcx rdx rsi rdi rsp rbp r15 rip\" \
    -o \"thread backtrace\" \
    -o \"disassemble --pc --count 20\" \
    -o \"process detach\" \
    -o \"quit\" 2>&1 | head -120
  echo === stdout of runner ===
  cat /tmp/d165-run.log
  echo === kill ===
  taskkill /F /PID \$WPID 2>&1 | head -1
'" 2>&1 | tee "$LOG"

echo "
=== output saved to $LOG ===" >&2
