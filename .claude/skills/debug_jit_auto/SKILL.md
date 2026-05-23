---
name: debug_jit_auto
description: JIT runtime debug toolkit (lldb/ndisasm/strace/SIGSEGV recipes for SEGV / miscompile investigation). Invoke when investigating SEGV, signal 11, exit code 139, mprotect issues, JIT byte stream disassembly, or any runtime crash in zwasm v2 codegen / interpreter.
---

# JIT / runtime debug toolkit — autonomous SEGV / miscompile recipes

> **Living document.** When you discover new tools, recipes, or
> workflow patterns during a debug session, **edit this file in
> the same commit as the fix** (or in a follow-up `chore(debug):`
> commit). Don't let the knowledge evaporate into chat history —
> the next debug session needs to find it via this skill's
> on-demand load. Adding a new recipe is cheap; re-deriving it from
> scratch is expensive.

Invoked when investigating SEGV / miscompile / runtime crash in JIT
codegen, interpreter, runtime, realworld runners, edge-case fixtures,
or anything under `private/spikes/`. Codifies the toolchain
established during §9.7 / 7.10-l (run-stage SEGV chunk-m investigation):
which tools live where, and copy-paste-ready batch-mode recipes that
the autonomous `/continue` loop can invoke without human-in-loop
debugger steering.

`extended_challenge.md` Step 4 explicitly authorises spikes +
WebFetch + reference-repo deep reads in autonomous scope. This file
is the **how** for runtime-debug spikes — the catalogue of tools that
already exist locally + the recipe shapes that fit the autonomous
loop.

## Tool inventory (post-7.10-l, ubuntunote-updated 2026-05-17, windowsmini-added 2026-05-22)

| Tool | Mac (nix `flake.nix`) | ubuntunote (`apt` / `nix profile`) | windowsmini (`install_tools.ps1`) | Purpose |
|---|---|---|---|---|
| `lldb` | `pkgs.lldb` (21.x) | Nix dev-shell via `flake.nix` (21.x) | LLVM bundle 22.1.6 at `C:\Program Files\LLVM\bin\lldb.exe` | batch-mode debugger; primary autonomous tool |
| `gdb` | not in flake (darwin gdb is finicky — codesign required) | `apt install gdb` (15.x) | n/a (use lldb) | Linux-side alternative to lldb |
| `ndisasm` / `nasm` | `pkgs.nasm` (3.x) | `apt install nasm` (2.16.x) | n/a (use llvm-objdump --disassemble -b binary) | raw byte stream → x86_64 disasm |
| `objdump` / `llvm-objdump` | clang's (in nix shell) | `apt install binutils` (default) | `llvm-objdump.exe` (LLVM bundle) | ELF / Mach-O / PE/COFF disasm |
| `llvm-readobj` | clang's | binutils default | LLVM bundle | PE/COFF / ELF inspection (symbols, sections, headers) |
| `llvm-symbolizer` | clang's | binutils default | LLVM bundle | backtrace symbolication |
| `strace` | not on Mac (use `dtruss` Apple-native) | `apt install strace` (6.8) | n/a (use **Procmon64.exe** — Sysinternals — for file/process/registry trace) | syscall / OS event trace (catches RWX page issues, file access timing) |
| `ltrace` | n/a | `apt install ltrace` (0.7.3) | n/a (lib call trace not first-class on Win) | libc / dynamic library call trace |
| `valgrind` | `pkgs.valgrind` (Linux only at flake level) | `apt install valgrind` (3.22) | n/a | heap analysis when DebugAllocator isn't enough |
| `bpftrace` | n/a (macOS lacks eBPF) | `apt install bpftrace` (0.20) + `bpfcc-tools` | n/a (ETW / WPR is the Win analog; not wired yet) | kernel-level dynamic tracing |
| `perf` | n/a | `apt install linux-tools-generic` | n/a (PerfView is the Win analog; not installed yet) | CPU profiling, branch / cache analysis |
| `qemu-x86_64` | n/a | `apt install qemu-user-static` | n/a (windowsmini is native x86_64) | cross-arch verification |
| `readelf` / `nm` | clang's | binutils default | `llvm-nm.exe` (LLVM bundle) | ELF / PE/COFF symbol inspection |
| `xxd` | available | available | `bash -c "xxd ..."` via Git-Bash; or PowerShell `Format-Hex` | hex dump / patch |
| `file` | available | `apt install file` | `bash -c "file ..."` via Git-Bash | quick arch / format identification |
| **`Procmon64.exe`** | n/a | n/a | Sysinternals bundle (`install_tools.ps1 -OnlyTool sysinternals`) — `%LOCALAPPDATA%\zwasm-tools\sysinternals-<date>\` | Process / file / registry trace. **D-028 wedge investigation primary tool**. Filter on Process Name → see exactly what zwasm-spec-runner.exe's spawn does (parent process wait, image scan delay, etc.) |
| **`procexp64.exe`** | n/a | n/a | Sysinternals bundle | Live process state, fd / handle count. **D-028 hypothesis #3 (fd-table fullness)** directly observable here — open Process Explorer → Find Handle → see handle count per process |
| **`handle64.exe`** | n/a | n/a | Sysinternals bundle | CLI fd/handle enumeration. `handle64.exe -p zwasm-spec-runner.exe` lists open handles of a specific process |
| **`Dbgview.exe`** | n/a | n/a | Sysinternals bundle | Capture `OutputDebugStringA/W` from any process. Useful when adding W3.b VEH-handler debug prints |
| **`tcpview64.exe`** | n/a | n/a | Sysinternals bundle | TCP/UDP connection viewer. Not core for JIT debug; included with bundle |

**Not viable / out of scope**: `rr` (record-and-replay) — needs
perf counters that virtualised hosts often don't expose
correctly; not yet installed on ubuntunote. If true record-
replay is needed on the native x86_64 host, run on bare metal
with `rr record` directly. **D-134's investigation** (LD_PRELOAD
sigaction shim + handler-entry probe + dmesg
`print-fatal-signals` + vanilla C reproducer) is documented in
the canonical pattern at
[`.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`](../../.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md);
the same shape applies to future SIGSEGV / signal-handling
oddities.

The `.dev/ubuntunote_setup.md` document carries the canonical
apt-vs-nix decision table (system-level vs project-pinned).
`.dev/orbstack_setup.md` is retained but reflects OrbStack's
**dev-scratch-only** role per ADR-0067 — debug tools listed
there are duplicates of the ubuntunote inventory at a slightly
older version.

## Autonomous recipe 1 — `lldb -b` first triage

For "where exactly does the SEGV happen" — fastest path:

```bash
lldb -b \
  -o "settings set target.x86-disassembly-flavor intel" \
  -o "process launch -- <argv>" \
  -o "register read" \
  -o "disassemble --pc --count 20" \
  -o "memory read --size 1 --count 256 \$pc" \
  -o "thread backtrace" \
  -o "quit" \
  ./path/to/binary 2>&1 | tee /tmp/lldb-segv.log
```

**Key flags**:
- `-b` = batch mode (auto-quit when commands finish)
- `-o "cmd"` = lldb command to execute in order
- `process launch -- <argv>` = pass argv to the process
- After SEGV, `register read` + `disassemble --pc` show the faulting site

**Reading the output**:
- `RIP` (x86_64) / `PC` (arm64) = faulting instruction address
- Subtract from `block.bytes.ptr` (printed by emit-pass diag) →
  byte offset within the JIT block
- Use `objdump -d -b binary -m i386:x86-64 -M intel` (or
  `ndisasm -b 64 -o <base>`) to disasm that byte range from the
  hex dump

## Autonomous recipe 2 — `ndisasm` for raw JIT byte stream

When the spike has dumped JIT block hex and we need to know
"what x86_64 instructions does this byte sequence decode to":

```bash
# Hex dump from spike code: write block.bytes to /tmp/jit.bin
ndisasm -b 64 /tmp/jit.bin | head -40
# Or with arbitrary base address (matches lldb's $pc display):
ndisasm -b 64 -o 0x1000 /tmp/jit.bin

# objdump alternative:
objdump -D -b binary -m i386:x86-64 -M intel /tmp/jit.bin | head -40
```

Both work; `ndisasm` is a single line of output per insn (easier
to grep). `objdump` matches lldb's display style.

## Autonomous recipe 3 — `strace` for mmap / mprotect inspection

When suspecting JIT block protection (e.g. RWX → RX transition
not happening, or `PROT_EXEC` not applied):

```bash
# ubuntunote only (Mac uses dtruss):
ssh ubuntunote 'cd ~/Documents/MyProducts/zwasm_from_scratch &&
    strace -f -e trace=mmap,mprotect,munmap \
        ./<binary> 2>&1' | grep -E "^mmap|^mprotect" | tail -20
```

Look for:
- `mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`
- `mprotect(addr, size, PROT_READ|PROT_EXEC)` — JIT block flip
- A `mprotect` with `PROT_EXEC = 4` flag is the executable transition

Mac equivalent (root-required):
```bash
sudo dtruss -f -t mprotect ./binary 2>&1 | tail -20
```

## Autonomous recipe 4 — SIGSEGV handler (no debugger)

When neither lldb nor gdb is available (or the segfault happens
before main reaches a debuggable state), install a Zig signal
handler in the spike code:

```zig
// In private/spikes/jit_segv/main.zig
const std = @import("std");

fn segvHandler(sig: c_int, info: *const std.posix.siginfo_t, ctx: ?*const anyopaque) callconv(.c) noreturn {
    _ = sig;
    _ = ctx;
    const fault_addr = info.fields.sigfault.addr;
    std.debug.print("\nSEGV at fault_addr={*} (siginfo)\n", .{fault_addr});
    // Print extracted RIP from the ucontext (platform-specific)
    // ... (see std.os.linux.ucontext for layout)
    std.process.exit(139);
}

pub fn main() !void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = &segvHandler },
        .mask = std.posix.empty_sigset,
        .flags = std.posix.SA.SIGINFO,
    };
    try std.posix.sigaction(std.posix.SIG.SEGV, &act, null);

    // ... reproduce the SEGV here ...
}
```

This buys the autonomous loop fault-address visibility WITHOUT
shelling out to a debugger. `siginfo_t.fields.sigfault.addr` is
the faulting memory address; the exact offset within the JIT
block is `(fault_addr - block.bytes.ptr)`.

## Autonomous recipe 5 — `private/spikes/jit_segv/` skeleton

When the realworld_run_jit runner segfaults but it's hard to
isolate which fixture / which op, build a minimal in-process
spike:

```
private/spikes/jit_segv/
├── README.md            ← what we're testing + findings
├── minimal.wasm.hex     ← hand-crafted 1-function wasm bytes
├── main.zig             ← compileWasm + dump bytes + invoke
└── build.zig            ← Zig build harness (maybe `zig build-exe`)
```

`extended_challenge.md` Step 4 grants spikes ≤ 1 day; outcomes
land as ADR (if rejected) / lesson (if observational) /
production code (if the fix). The `private/spikes/` directory
is gitignored — only the lessons / ADRs persist.

## Recipe 6 — bisection by Wasm op

Hand-craft a series of progressively-larger wasm modules to
binary-search the SEGV-triggering op family:

1. `(func)` — empty
2. `(func) (i32.const 0) (drop)` — i32.const + drop
3. `(func) (i32.const 0) (i32.const 0) (i32.add) (drop)` — i32.add
4. `(func (param i32)) (local.get 0) (drop)` — local.get
5. ... continue until SEGV reproduces.

Each step → compile → invoke → check exit code. The op family
that flips from "exit 0" to "SIGSEGV" is the regression source.
Bisection cost: log₂(N) compiles to localise to ≤ 1 op family.

## Recipe 7 — crash-time JIT context dump (async-signal-safe)

When a SEGV reproduces inside the JIT body and you want fault
context (faulting address, surrounding bytes, RIP) WITHOUT a
debugger attached, install a `SA.SIGINFO` handler that writes
raw bytes via async-signal-safe primitives only. Reference
implementation: `test/spec/spec_assert_runner_base.zig`
(`sigsegvHandler` + `installSigsegvHandler`). The pattern:

```zig
const std = @import("std");

fn handler(sig: c_int, info: *const std.posix.siginfo_t, _: ?*const anyopaque) callconv(.c) noreturn {
    _ = sig;
    // siginfo.fields.sigfault.addr is the faulting address.
    // Async-signal-safe: only raw writes; no allocator, no
    // formatted std.debug.print (which acquires a mutex).
    const fault_addr = @intFromPtr(info.fields.sigfault.addr);
    var buf: [128]u8 = undefined;
    const n = std.fmt.bufPrint(&buf, "SEGV at 0x{x}\n", .{fault_addr}) catch buf[0..0];
    _ = std.posix.write(std.posix.STDERR_FILENO, n) catch {};
    std.c._exit(142);  // 142 distinct from 139 to disambiguate
                       // "our handler ran" vs "kernel killed us".
}

// In main, before invoking the JIT:
const SS = 1 << 18;  // 256 KB altstack — required for stack-
                     // exhaustion SEGV cases (assert_exhaustion).
var stack: [SS]u8 align(std.heap.page_size_max) = undefined;
std.posix.sigaltstack(&.{ .sp = &stack, .flags = 0, .size = SS }, null) catch {};
var act: std.posix.Sigaction = .{
    .handler = .{ .sigaction = &handler },
    .mask = std.posix.sigemptyset(),
    .flags = std.posix.SA.ONSTACK | std.posix.SA.SIGINFO,
};
std.posix.sigaction(.SEGV, &act, null);
// Optionally also SIGBUS for Mach-side mis-aligned access:
std.posix.sigaction(.BUS, &act, null);
```

**Don't do** in a signal handler:
- `std.debug.print` (acquires a mutex, deadlocks if interrupted
  thread held it).
- Allocator calls (likewise re-entrant).
- `std.fs` / `std.Io` non-raw paths.
- Any libc function not in the POSIX async-signal-safe list
  (`man 7 signal-safety`).

**Do**:
- `std.posix.write` to a fixed-size stack buffer.
- `std.c._exit` (not `exit` — atexit handlers may not be
  async-signal-safe).
- `siglongjmp` to a previously-set `sigsetjmp` recovery point
  (use only when the saved frame is provably alive).

**Exit-code disambiguation** (d-71 lesson): pick an exit code
DIFFERENT from `139` (= 128 + SIGSEGV, the kernel's default
exit code when no handler installed). Otherwise a
`zig build` report of "exited with code 139" is ambiguous
between "your handler ran and chose 139" and "the kernel
killed the process before your handler installed". The
spec_assert runner uses `142` for this reason.

**When to factor out**: while only one site uses this pattern
today, the second site (e.g. a JIT-execution sentinel runner
for cross-host differential diagnosis per ADR-0034) should
extract a `src/diagnostic/jit_dump.zig` module rather than
duplicate. Until then, copy the pattern from spec_assert and
adapt the recovery target.

## Recipe 8 — fault-address poison-pattern decoding (FIRST step on every SEGV)

Per D-142 cycle 6 (2026-05-17): **the very first action on any
SEGV is to capture the fault address from `siginfo_t.addr`
via SA_SIGINFO and decode its pattern**. The pattern usually
identifies the bug class in seconds, narrowing which recipe
above to invoke next.

The infrastructure is already in place at
`test/spec/spec_assert_runner_base.zig::sigsegvHandler`
(SA_SIGINFO upgrade landed in commit `dd0cd332`); the
unarmed-branch trace emits
`(handler-entry=N last-armed=M fault-addr=0xNNNN...)`
automatically. For new SEGV-prone code paths, install the same
sa_sigaction + `siginfo.addr` emission pattern.

### Pattern cheatsheet

| Fault address pattern | Likely cause | Decode example |
|---|---|---|
| `0xAA...AA` ± small offset | Zig `undefined` poison (Debug only) — uninitialised memory dereferenced. The low byte reveals the offset from the poison base: `0xB2 = 0xAA + 8`, `0xCC = 0xAA + 0x22`, etc. | `0xaaaaaaaaaaaaaab2` ⇒ uninit pointer deref at `+8`. Trace back: which field is at offset 8 of an extern struct that was constructed with `.foo = undefined`? See `.claude/rules/zig_tips.md` `undefined in extern struct` entry. |
| `0xCC...CC` ± small offset | x86 INT3 / Zig safety-stub remnant. Often inside a freed or de-init'd region. | grep for `@memset(buf, 0xCC)` or look for use-after-free. |
| `0xDEADBEEF` / `0xDEAD_DEAD` | Sentinel value. Check `linker.IMPORT_SENTINEL_OFFSET` (`0xFFFF_FFFF`), `@ptrFromInt(0xDEADBEEF)` patterns. | grep `0xDEAD` / `IMPORT_SENTINEL`. |
| `0xFFFF_FFFF` / `0xFFFF_FFFF_FFFF_FFFF` | sentinel "no value"; for slices, `len = maxInt(u32)` etc. | check the slice's len/cap fields. |
| Near current SP (within 8 KB of `mov sp, sp`) | Stack-guard hit (stack overflow). | compare against pthread stack info via `pthread_attr_getstack`; check for deep recursion. |
| Mac aarch64 `0x1xx_xxxxxx` | `.text` or MAP_JIT region. Cross-check `otool -tv <binary>` (Recipe 1 / 2). | likely a code-address fault (bad function pointer load or RX page that wasn't mapped X). |
| Linux x86_64 `0x40_xxxx_xxxx` / `0x55_xxxx_xxxx` | `.text` or MAP_JIT region. | `/proc/self/maps` cross-check. |
| `0x0` or low (< 0x1000) | NULL deref. | trivially `*null`; check optional unwrap sites. |
| Large random-looking address (e.g. `0x7fff_xxxx_xxxx`) | Likely valid stack / heap area but wrong contents. | use Recipe 1 to capture register state + check pointer provenance. |

### Why first-step

Without the fault address, every SEGV investigation starts by
guessing the bug class from the symptom. The address narrows
the search **before** committing to a specific recipe. D-142
spent 5 cycles rejecting hypotheses (PAC, siglongjmp re-entry,
altstack, layout, MAP_JIT-flip) before the fault-address
emission landed; cycle 6 identified the poison pattern in
under a minute.

### When the pattern doesn't match the cheatsheet

Capture the address anyway and add a row to this table in
the same commit that closes the bug. The cheatsheet's
value is cumulative.

## Windows recipes (windowsmini-specific, added 2026-05-22)

The POSIX-signal-model recipes (1, 4, 7) DON'T apply cleanly on
Win64 — Windows uses Vectored Exception Handling (VEH) +
Structured Exception Handling (SEH) instead of `sigaction` /
`sigsetjmp`. Until D-136 / W3.b lands the VEH bridge (per
ADR-0103), Windows-side trap recovery is **not present** — any
SEGV / OOB / illegal-instruction in JIT code terminates the
process outright. These recipes work around that.

Common SSH invocation pattern for all Windows recipes:

```bash
# From Mac: drop into windowsmini's PowerShell or Git-Bash
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"<cmd>\""
ssh windowsmini "bash -lc '<cmd>'"
```

### Recipe 9 — `lldb -b` first triage on windowsmini (SSH)

Mirror of Recipe 1, adapted for Win64 PE/COFF:

```bash
ssh windowsmini "bash -lc '
  cd ~/Documents/MyProducts/zwasm_from_scratch
  lldb -b \
    -o \"settings set target.x86-disassembly-flavor intel\" \
    -o \"process launch -- <argv>\" \
    -o \"register read\" \
    -o \"disassemble --pc --count 20\" \
    -o \"memory read --size 1 --count 256 \\\$pc\" \
    -o \"thread backtrace\" \
    -o \"quit\" \
    ./zig-out/bin/<exe>.exe 2>&1
'"
```

**Differences from POSIX**:
- Register names: `RIP` / `RSP` / `RBP` same as Linux x86_64
- Symbol resolution uses PE/COFF + .pdb (Zig emits both for
  debug builds); lldb auto-discovers .pdb files next to .exe
- `EXCEPTION_ACCESS_VIOLATION` is the Win64 equivalent of
  SIGSEGV — lldb on Windows prints "stop reason = Exception
  Access violation".

### Recipe 10 — `Procmon64.exe` for process spawn / file access trace (D-028 primary)

Procmon captures every file / process / registry / network
event with timestamp. Killer tool for D-028 wedge: see exactly
which child-process spawn hangs and what files are being
scanned at that moment.

```bash
# Manual interactive (from windowsmini desktop):
#   1. Procmon64.exe → start capture
#   2. Filter: Process Name contains "zwasm" OR contains "zig"
#   3. Run: zig build test-all in another shell
#   4. After wedge: File → Save → CSV or PML
#   5. Look for: Process Create events + the millisecond gap
#      before/after suspect runner transition (wast_runner exit →
#      spec_assert_runner start)

# Headless (SSH-driven) capture via /BackingFile + /Quiet:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  Start-Process -FilePath 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\Procmon64.exe' \
    -ArgumentList '/Quiet','/Minimized','/BackingFile','C:\Users\shota\procmon-trace.pml','/AcceptEula'
\""
# Run test-all in another SSH session
# Then:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  & 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\Procmon64.exe' /Terminate
\""
# Then SCP procmon-trace.pml back to Mac and open with Procmon GUI
# (Procmon native PML format is not text-readable; export to CSV via GUI for grep)
```

**What to look for in the trace** (D-028 wedge specifically):
- Long gaps (>10 s) between `Process Create` for one runner
  and its first `File Read` event → image scan delay
- `CreateFile` events on `.exe` files from `MsMpEng.exe`
  (Defender process) interleaved with zwasm process spawn →
  confirms Defender hypothesis (#5 in D-028)
- Sudden burst of handle / file events at runner transition →
  hypothesis #3 evidence

### Recipe 11 — `handle64.exe` for fd / handle count (D-028 #3 probe)

D-028 hypothesis #3 says "fd-table fullness at runner
transition". Test directly:

```bash
# Snapshot of all open handles for a specific process:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  & 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\handle64.exe' \
    -p zwasm-spec-runner.exe -accepteula
\""

# Per-process count (rough):
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  & 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\handle64.exe' \
    -p zwasm-spec-runner.exe -accepteula 2>\\\$null | Measure-Object -Line
\""

# All processes with high handle count:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  Get-Process | Sort-Object -Property HandleCount -Descending | Select-Object -First 10 Name, HandleCount, Id
\""
```

**Expected baseline**: zwasm test runners typically hold
50-200 handles. If a wedged process shows >5000 handles,
hypothesis #3 is confirmed.

### Recipe 12 — `llvm-objdump` PE/COFF JIT byte disasm

Mirror of Recipe 2, adapted for Win64. Since the JIT-emitted
bytes are NOT in a PE/COFF file (they live at mmap'd memory),
the same `--disassemble -b binary` form works:

```bash
ssh windowsmini "bash -lc '
  # Hex dump from spike code: write block.bytes to /tmp/jit.bin (via lldb memory write -outfile)
  llvm-objdump --disassemble -b binary -m x86_64 --x86-asm-syntax=intel /tmp/jit.bin
'"

# To inspect an actual PE/COFF binary (test exe symbols, sections):
ssh windowsmini "bash -lc '
  llvm-readobj --headers --sections --symbols ./zig-out/bin/zwasm-spec-runner.exe
'"

# To dump only the .text section disasm:
ssh windowsmini "bash -lc '
  llvm-objdump --disassemble --section=.text ./zig-out/bin/zwasm-spec-runner.exe | head -200
'"
```

### Recipe 13 — `Dbgview.exe` + `OutputDebugStringA` for VEH handler verification (W3.b post-land)

**Placeholder until W3.b SEH bridge implementation lands.**

When `src/platform/windows_traphandler.zig` is implemented per
ADR-0103, instrument the `vehHandler` entry point with
`OutputDebugStringA("[veh] hit RIP=...")` calls. Capture with:

```bash
# Manual: launch Dbgview.exe on windowsmini desktop, "Capture Win32" + "Capture Events"
# Then run the test that triggers VEH

# Programmatic launch:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  Start-Process -FilePath 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\Dbgview.exe' \
    -ArgumentList '/g','/t','/k','/l','C:\Users\shota\veh-trace.log'
\""
```

`OutputDebugStringA` is the most reliable async-signal-safe-ish
escape hatch on Windows for VEH handler observation; printf is
not safe in VEH context (loader lock, etc.).

### Recipe 14 — Crash dump (WER `.dmp`) post-mortem with lldb

When a Win64 test crashes outright (no recovery, process kill),
Windows Error Reporting auto-drops a `.dmp` file to
`%LOCALAPPDATA%\CrashDumps\` (path is in ExclusionPath per
2026-05-22 setup). lldb on Windows can read these:

```bash
ssh windowsmini "bash -lc '
  ls -la /c/Users/shota/AppData/Local/CrashDumps/
  lldb -c /c/Users/shota/AppData/Local/CrashDumps/zwasm-spec-runner.exe.<pid>.dmp \
    -o \"thread backtrace all\" \
    -o \"register read\" \
    -o \"quit\"
'"
```

**Enabling WER dump collection** (one-time, requires admin —
or PowerShell ssh if user has admin):

```powershell
# Set per-app dump config for zwasm runners (DumpType 2 = full mini-dump):
$reg = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
New-Item -Path "$reg\zwasm-spec-runner.exe" -Force
Set-ItemProperty -Path "$reg\zwasm-spec-runner.exe" -Name DumpType -Value 2
Set-ItemProperty -Path "$reg\zwasm-spec-runner.exe" -Name DumpFolder -Value 'C:\Users\shota\AppData\Local\CrashDumps'
Set-ItemProperty -Path "$reg\zwasm-spec-runner.exe" -Name DumpCount -Value 10
```

(Not yet applied on windowsmini as of 2026-05-22 — add when
first Win64 crash needs post-mortem analysis.)

### Recipe 15 — `ssh windowsmini cmd /c '...'` stable orchestration (HANG / interactive debug)

Codifies the 8-trap learning from D-165 cycle 9
(`.dev/lessons/2026-05-23-windowsmini-ssh-quoting-traps.md`).
The default OpenSSH shell on windowsmini is PowerShell 7;
nesting `bash -lc` re-enters Git-Bash with MSYS path
conversion. Both layers introduce quoting traps that bite
hard at exactly the wrong moment (during root-cause hunts).

**Stable form** — bypasses PowerShell + Git-Bash + MSYS:

```bash
ssh windowsmini cmd /c "<windows-cmd-with-windows-paths>"
```

Inside the double-quoted string, `cmd /c` interprets
Windows-native switches (`/F`, `/FI`, `/T`, `/NOBREAK`, etc.)
without path conversion. Chain commands with cmd `&&`:

```bash
ssh windowsmini 'cmd /c "cd /d C:\Users\shota\Documents\MyProducts\zwasm_from_scratch && git fetch origin zwasm-from-scratch && git reset --hard origin/zwasm-from-scratch && zig build install"'
```

Note: `cd /d <path>` forces drive change too — required when
the SSH-default shell starts on a different drive.

**8 specific traps + fixes** (see lesson file for full
detail):

1. PowerShell parses bash `$var` → use `bash -lc "'...'"` OR `cmd /c '...'`.
2. PowerShell parses `(...)` / `foreach($p in ...)` → `cmd /c` or `.ps1` file.
3. MSYS path-converts `/F` `/FI` args → `cmd /c` bypass (preferred).
4. `tasklist /FI` filter quoting → `cmd /c 'tasklist /FI "..." /NH /FO CSV'`.
5. Cygwin PID ≠ Win-native PID → re-fetch via tasklist.
6. SSH background `&` doesn't auto-detach → `< /dev/null` + redirect logs.
7. tasklist header row → `/NH /FO CSV`.
8. lldb attach works without admin — verified.

**Log file locations**:
- `%USERPROFILE%\d165-win.log` is a friendly Windows path.
- `C:\tmp\` does NOT exist by default (don't write there).
- For pulling back to Mac: `scp -q windowsmini:d165-win.log /tmp/d165-win.log`.

### Recipe 16 — JIT bytes dump via runner instrumentation (HANG-friendly, no debugger)

When you suspect a JIT-emitted body has bad bytes (and the
runtime hangs / corrupts / loops infinitely so `lldb -b -o
"process launch"` can't reach the bug site without manual
interrupt), instrument the runner to dump the bytes BEFORE
execution. Pre-execution dump bypasses the hang.

D-165 cycle 9 pattern (now reverted; reference for re-introduction):

```zig
// in test/spec/spec_assert_runner_base.zig at module-load site
// (after current_compiled = compiled;):
for (compiled.func_results, 0..) |*fr, def_idx| {
    const wasm_idx = compiled.num_imports + @as(u32, @intCast(def_idx));
    std.debug.print("[<tag>] func{d} (wasm_idx={d}) len={d} bytes=", .{ def_idx, wasm_idx, fr.out.bytes.len });
    for (fr.out.bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
}
```

(Currently `std.posix.getenv` / `std.process.getEnvVarOwned`
both unavailable in 0.16 stdlib at this surface; `std.c.getenv`
re-introduces libc concern. Cycle 9 used `if (true)` unconditional
+ revert. Future re-introduction: pick one and codify.)

Run, redirect stderr to file, scp back to Mac:

```bash
# Win-side: dump to file
ssh windowsmini 'cmd /c "cd /d <repo> && start /B zig-out\bin\zwasm-spec-wasm-2-0-assert.exe <manifest-dir> > %USERPROFILE%\d165-win.log 2>&1"'
sleep N  # wait for compile + dump to finish, before any hang
ssh windowsmini 'cmd /c "taskkill /F /IM zwasm-spec-wasm-2-0-assert.exe 2>nul"'
scp -q windowsmini:d165-win.log /tmp/d165-win.log

# Mac-side: extract a specific function's bytes and disassemble
grep "func7" /tmp/d165-win.log | awk -F'bytes=' '{ print $2 }' \
    | xxd -r -p > /tmp/func7.bin
llvm-objdump --disassemble -b binary -m x86_64 --x86-asm-syntax=intel /tmp/func7.bin
```

This dumped fac-ssa's 390-byte body and was on the critical
path to identifying the pick0/pick1 MEMORY-class + cap=1
bugs in D-165 cycle 9.

### Recipe 17 — manifest-bisect via `test/private/d-165/` scratch dir

To isolate which directive triggers a JIT-runtime bug:

1. `cp test/spec/wasm-2.0-assert/<feature>/fac.0.wasm
   test/private/d-165/fac/` — copies the upstream wasm.
2. Write a custom `test/private/d-165/fac/manifest.txt` with
   progressively-narrowed directives.
3. Run `zig-out/bin/zwasm-spec-wasm-2-0-assert test/private/d-165`.
4. Iterate: bisect by adding/removing directives until you
   isolate the minimal trigger (Recipe 17a — 1 cycle ≈ 5-15
   seconds round-trip via scp + cmd /c).

`test/private/` is gitignored — no commit pressure for the
scratch fixture. Reverts to base state by `rm -rf test/private/d-165/fac/*; cp ... fac.0.wasm fac/`.

`installArtifact(non_simd_assert_runner_exe)` in `build.zig`
ensures `zig-out/bin/<runner>` is the stable canonical path
(landed cycle 9 / `12fb9e4f`). Without this you'd hunt for
the latest `.zig-cache/o/HASH/<runner>.exe` per build.

## When to invoke each recipe (decision tree)

```
Host = Mac / ubuntunote?
├── SEGV reproduces in test-realworld-run-jit?
│   ├── YES → Recipe 1 (lldb -b) for first triage. Read fault RIP.
│   │        ├── RIP inside JIT block (block.bytes.ptr ≤ RIP < ptr+len)?
│   │        │   ├── YES → Recipe 2 (ndisasm) on the byte range.
│   │        │   │        Identify the faulting x86 insn → trace back
│   │        │   │        to the emit-pass site that produced it.
│   │        │   │        → Likely candidates: prologue stack
│   │        │   │          alignment, spill region overflow, trap
│   │        │   │          stub address calc.
│   │        │   └── NO → not in JIT body. Check entry shim
│   │        │            (entry.zig), runtime ptr passing, or
│   │        │            JitRuntime layout (Recipe 3).
│   │        └── Crash before lldb attaches?
│   │            └── Recipe 4 (SIGSEGV handler) instead.
│   │
│   ├── NO but suspect mprotect issue?
│   │   └── Recipe 3 (strace) for mmap/mprotect timeline.
│   │
│   └── Hard to localise to one fixture?
│       └── Recipe 5 (spike) + Recipe 6 (bisection).
│
└── Host = windowsmini?
    ├── Process wedges / hangs at runner transition (D-028 shape)?
    │   ├── First: Recipe 11 (handle64 fd count) — hypothesis #3 probe
    │   └── Then: Recipe 10 (Procmon trace) — see what spawn does
    │
    ├── Crash / EXCEPTION_ACCESS_VIOLATION?
    │   ├── If WER dump available: Recipe 14 (post-mortem)
    │   ├── If reproducible under lldb: Recipe 9 (lldb -b, SSH form)
    │   └── If JIT bytes need disasm: Recipe 12 (llvm-objdump PE)
    │
    └── W3.b VEH bridge work (D-136 impl)?
        └── Recipe 13 (Dbgview + OutputDebugString) for VEH entry trace
```

## Lessons / ADR landing

Per `.claude/rules/lessons_vs_adr.md`:
- Spike outcome that's observational ("we tried X, learned Y") →
  lesson at `.dev/lessons/<date>-<slug>.md`
- Spike outcome that's load-bearing decision ("X is rejected
  because Y") → ADR at `.dev/decisions/NNNN_<slug>.md`
- Production fix → normal source commit

Always cite the concrete `lldb -b` output / `ndisasm` line / etc.
in the commit body — the recipe + finding lineage matters for
future-you debugging similar SEGVs.

## How this file evolves (meta — read on every load)

This file is a **living toolkit**, not a frozen reference. The
autonomous loop is expected to extend it whenever new ground is
covered. Concretely:

- **New tool installed** (Mac via `flake.nix` / `pkgs.X` or
  Ubuntu via `apt install Y`)? Add it to the **Tool inventory**
  table with one-line purpose. Mention which platform.
- **New recipe figured out** (e.g. a specific `gdb -ex` chain
  that auto-extracts JIT bytes around a crash, or a `strace`
  filter that catches a particular runtime quirk)? Add it as
  a numbered Recipe with a copy-paste block.
- **Tried-and-rejected tool** (e.g. `rr` requires perf counters
  that aren't exposed everywhere)? Note it in **Not viable** /
  **Not in scope** so the next session doesn't re-pay the trial
  cost.
- **Tool installation gap discovered** (e.g. ndisasm missing
  on a host)? Update `.dev/ubuntunote_setup.md` / `flake.nix`
  AND the inventory table here in the same commit.

**Edit triggers** (when this skill is loaded, scan for these):
- Are you about to debug a SEGV / miscompile / runtime crash?
  → Apply the decision tree at the bottom.
- Did you just finish such a debug session?
  → Did you use a tool / recipe NOT documented here? Add it.
- Did you install a new tool to the dev environment? → Inventory
  table.

**Don't be precious about edits.** A new recipe with rough
copy-paste output is more valuable than a polished prose entry.
Aim for "future-me can grep this file and find the exact
incantation" not "this reads like documentation".

## Cross-references

- `extended_challenge.md` — autonomous self-resolution discipline
  (spikes, WebFetch, reference-repo deep reads). This skill is
  the toolkit; that rule is the policy.
- `lessons_vs_adr.md` — where to land the FINDINGS (lesson vs
  ADR vs production code).
- `bug_fix_survey.md` — once root-caused, grep for siblings.
- `.dev/ubuntunote_setup.md` — canonical apt/Nix install lines
  for the native x86_64 Linux gate host (post-ADR-0067).
- `.dev/orbstack_setup.md` — retained for dev-scratch use only
  (no longer the per-chunk gate host per ADR-0067).
- `.dev/windows_ssh_setup.md` — windowsmini setup; see its
  "Interactive JIT debug session" section for canonical SSH-
  side workflow (lldb-attach, Procmon launch, WER dump
  collection). Recipes 9-14 above are the toolkit; setup.md
  is the host-side prerequisite list.
