#!/usr/bin/env bash
#
# jit_value_trace.sh — inspect register / memory VALUES inside JIT-emitted
# code (arm64 / macOS). A value-trace harness for miscompiles that produce
# wrong output but DON'T crash (so lldb's crash-triage recipes don't apply).
#
# It automates the lldb-on-JIT flow that took ~9 manual attempts to pin down
# (lesson `2026-06-15-lldb-value-trace-on-jit-code`): JIT bodies have no
# symbols and live in runtime-mmap'd W^X pages, so a raw-address breakpoint
# set before `run` is resolved but NEVER inserted. The trick: stop first at a
# real Zig symbol that runs mid-execution, THEN arm the JIT-address breakpoint.
#
# Backed by the permanent `ZWASM_DEBUG=jit.dump` primitives
#   - compile.zig : `[jit.dump] func=N len=L hex=...`        (body-relative bytes)
#   - setup.zig   : `[jit.dump] func=N runtime_addr=0xADDR`  (absolute entry)
#
# Subcommands:
#   addr   <wasm> <func_idx>
#       Print func's stable runtime entry address (disable-aslr → identical
#       across runs, so an address from one run is valid for the next).
#
#   disasm <wasm> <func_idx>
#       Disassemble the func to /tmp/jit_func<idx>.asm (jit.dump → llvm-mc;
#       NOTE: llvm-objdump/Apple objdump dropped `-b binary`, llvm-mc is the
#       working path). Each asm line N (1-based) is at byte offset (N-1)*4.
#
#   trace  <wasm> <func_idx> <asm_line> [stop_symbol] [post_cmds_file]
#       Break at <stop_symbol> (default: fdWrite — the WASI host write, always
#       hit when a program prints) so the JIT page is mapped, then arm a
#       HARDWARE bp at func<idx>_addr + (asm_line-1)*4 and dump registers at
#       the hit. Append extra lldb `-o` commands (one per line) via the
#       optional post_cmds_file (e.g. `memory read --size 4 --count 4 \`$x28+0x808\``).
#
# Engine is always --engine jit. Build first: `zig build`.
#
# WASI guest→host map (useful stop symbols / locals):
#   JIT guest → wasi.jit_dispatch.fd_write (Zig shim; rt.vm_base = guest mem
#   base, rt.mem_limit = size) → wasi.fd.fdWrite. Break PAST the prologue
#   (`br set -f jit_dispatch.zig -l 78`) for Zig locals to resolve.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZWASM="$REPO/zig-out/bin/zwasm"

die() { echo "jit_value_trace: $*" >&2; exit 1; }

find_tool() { # $1 = binary name, $2 = nix-store name fragment
  local t
  t="$(command -v "$1" 2>/dev/null || true)"; [ -n "$t" ] && { echo "$t"; return 0; }
  t="$(ls -d /nix/store/*"$2"*/bin/"$1" 2>/dev/null | head -1 || true)"
  [ -n "$t" ] && { echo "$t"; return 0; }
  return 1
}

[ -x "$ZWASM" ] || die "missing $ZWASM — run 'zig build' first"
LLDB="$(find_tool lldb lldb- || true)"
LLVM_MC="$(find_tool llvm-mc llvm- || true)"

runtime_addr() { # $1 wasm  $2 func_idx  — stable under disable-aslr
  [ -n "$LLDB" ] || die "lldb not found (PATH or /nix/store/*lldb-*/bin/lldb)"
  ZWASM_DEBUG=jit.dump "$LLDB" -b \
    -o "settings set target.disable-aslr true" -o run -o quit \
    -- "$ZWASM" run --engine jit "$1" 2>&1 \
  | grep -oE "func=$2 runtime_addr=0x[0-9a-f]+" | head -1 | grep -oE "0x[0-9a-f]+"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  addr)
    [ $# -ge 2 ] || die "usage: addr <wasm> <func_idx>"
    a="$(runtime_addr "$1" "$2")"; [ -n "$a" ] || die "no runtime_addr for func $2"
    echo "func=$2 runtime_addr=$a" ;;

  disasm)
    [ $# -ge 2 ] || die "usage: disasm <wasm> <func_idx>"
    [ -n "$LLVM_MC" ] || die "llvm-mc not found (/nix/store/*llvm-*/bin/llvm-mc)"
    out="/tmp/jit_func$2.asm"
    hex="$(ZWASM_DEBUG=jit.dump "$ZWASM" run --engine jit "$1" 2>&1 \
           | grep -oE "func=$2 len=[0-9]+ hex=[0-9a-f]+" | sed -E 's/.*hex=//')"
    [ -n "$hex" ] || die "no jit.dump bytes for func $2"
    echo "$hex" | sed -E 's/(..)/0x\1 /g' \
      | "$LLVM_MC" --disassemble --triple=aarch64 > "$out"
    echo "wrote $out ($(wc -l < "$out" | tr -d ' ') insns); line N → byte offset (N-1)*4" ;;

  trace)
    [ $# -ge 3 ] || die "usage: trace <wasm> <func_idx> <asm_line> [stop_symbol] [post_cmds_file]"
    wasm="$1"; idx="$2"; line="$3"; stop="${4:-fdWrite}"; post="${5:-}"
    a="$(runtime_addr "$wasm" "$idx")"; [ -n "$a" ] || die "no runtime_addr for func $idx"
    bp="$(printf '0x%x' $(( a + (line - 1) * 4 )))"
    echo "func=$idx entry=$a  bp(line $line)=$bp  stop=$stop" >&2
    post_opts=()
    if [ -n "$post" ] && [ -f "$post" ]; then
      while IFS= read -r l; do [ -n "$l" ] && post_opts+=(-o "$l"); done < "$post"
    else
      post_opts=(-o "register read")
    fi
    ZWASM_DEBUG=jit.dump "$LLDB" -b \
      -o "settings set target.disable-aslr true" \
      -o "br set -n $stop" \
      -o run \
      -o "br set -H -a $bp" \
      -o "br disable 1" \
      -o continue \
      "${post_opts[@]}" \
      -o kill -o quit \
      -- "$ZWASM" run --engine jit "$wasm" ;;

  *) die "usage: $(basename "$0") {addr|disasm|trace} <wasm> <func_idx> [...]" ;;
esac
