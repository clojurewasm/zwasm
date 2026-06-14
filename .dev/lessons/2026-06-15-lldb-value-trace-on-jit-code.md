# lldb value-trace on JIT-emitted code (arm64, macOS)

**Context**: tracing a JIT *value* miscompile (not a crash) — D-330
c_sha256 `\n` — needs register/memory inspection inside JIT code. JIT
bodies have no symbols and live in runtime-mmap'd pages, which breaks
the naïve `lldb -b -o "br set -a <addr>"` flow. Established 2026-06-15
with the new `ZWASM_DEBUG=jit.dump` primitives (`db3109d8`/`f49b3675`).

## The method (verified)

1. **Stable addresses**: `settings set target.disable-aslr true` →
   JIT mmap addresses are identical across runs, so a `runtime_addr`
   captured in one run is valid for the next.
2. **Map frames → funcs**: `ZWASM_DEBUG=jit.dump` prints
   `func=N runtime_addr=0xADDR` (setup.zig). A `bt` at any host
   breakpoint shows JIT frames as bare `0xADDR` (no symbol); compare
   against the dump list to name them. (c_sha256: frame in
   `[0x..cd964, 0x..ce37c)` = func 11 `__stdio_write`.)
3. **Arm raw-address bps AFTER the JIT page maps** — the core gotcha.
   `br set -a <jit_addr>` issued before `run` resolves the address but
   is **never inserted** (the page isn't mapped yet, and lldb does not
   re-arm raw-address bps when new memory appears). Stop first at a
   real Zig symbol that runs mid-execution (`br set -n fdWrite`), THEN
   `br set -a <jit_addr>`, then `continue`.
4. **WASI guest→host boundary**: JIT guest → `wasi.jit_dispatch.fd_write`
   (Zig shim; `rt.vm_base` = guest linear-memory base, `rt.mem_limit`
   = size) → `wasi.fd.fdWrite`. Break at the SHIM, not the guest, for
   clean access to the iovec args.
5. **Break PAST the prologue** — `br set -n fd_write` lands at the
   function entry (line 71) where params aren't yet stored to stack →
   `p iovs_len` is empty / garbage. Use a body line
   (`br set -f jit_dispatch.zig -l 78`) so Zig locals resolve. (The
   inner `fdWrite` resolved usefully at `+72` = fd.zig:82.)

## Reusable harness — `scripts/jit_value_trace.sh`

Don't re-derive the above by hand. The script wraps it:
  - `addr   <wasm> <idx>`        — stable runtime entry address
  - `disasm <wasm> <idx>`        — → `/tmp/jit_func<idx>.asm` (llvm-mc)
  - `trace  <wasm> <idx> <line> [stop_symbol] [post_cmds_file]` — arm a
    `-H` bp at `entry+(line-1)*4` after stopping at `stop_symbol`; dump
    registers (or run the `post_cmds_file` lldb commands).
Auto-discovers nix-store lldb/llvm-mc. **VALIDATED**: a `-H` bp fires on
a JIT page (func 11 `__stdio_write` entry hit) — so a *non*-firing bp is
a real "not executed on this path" signal, not a methodology gap.

## Buffering gotcha (cost me the first value-trace)

When the guest's stdout is a **pipe/redirect (not a tty)**, musl uses
**FULL buffering**: every `printf` buffers via `putc`, and the stream
flushes **once at program exit** → the FIRST `fdWrite` is the exit
flush, AFTER all `putc`. So arming a `putc`-path bp at `fdWrite` is too
late. To trace `putc`-side guest code, stop EARLIER (e.g. an earlier
host call, or the JIT entry) before any buffering runs.

## Payoff for D-330

The c_sha256 final-`\n` drop is a `putc`-into-buffer miss that precedes
the single exit `fdWrite` (full-buffered pipe). Next probe: stop before
buffering (not at `fdWrite`), arm the harness on func 4's putc store of
the final `\n`, check the store/wpos-increment. Then compare the exit
`fdWrite` iovec `buf_len`s (`mem[vm_base+iovs_ptr+{4,12}]`) interp-vs-jit.
