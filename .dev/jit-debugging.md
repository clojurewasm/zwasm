# JIT Debugging Techniques

Reference for debugging ARM64 JIT code generation issues.

## 1. Dump & Disassemble Generated Machine Code

The most effective technique. Dump the mmap'd buffer to a binary file,
wrap in a minimal ELF, and disassemble with LLVM objdump.

### Dump from `finalize()` in jit.zig

```zig
// Add temporarily in Compiler.finalize(), after @memcpy:
if (condition) { // e.g. self.reg_count == 11
    const file = std.fs.cwd().createFile("/tmp/jit_dump.bin", .{}) catch null;
    if (file) |f| { defer f.close(); f.writeAll(src_bytes) catch {}; }
}
```

### Create ELF wrapper and disassemble

```bash
python3 -c "
import struct
with open('/tmp/jit_dump.bin', 'rb') as f: code = f.read()
sz = len(code)
ehdr = b'\x7fELF' + bytes([2,1,1,0]) + b'\x00'*8
ehdr += struct.pack('<HHIQQQIHHHHHH', 0xB7, 183, 1, 0x400000, 64, 0, 0, 64, 56, 1, 0, 0, 0)
phdr = struct.pack('<IIQQQQQQ', 1, 5, 120, 0x400000, 0x400000, sz, sz, 0x1000)
with open('/tmp/jit_dump.elf', 'wb') as f: f.write(ehdr + phdr + code)
"
objdump -d /tmp/jit_dump.elf
```

## 2. Register IR Dump

Dump the RegInstr array to understand what the JIT is trying to compile:

```zig
for (reg_func.code, 0..) |instr, i| {
    std.debug.print("[{d:2}] op=0x{X:0>4} rd={d:2} rs1={d:2} operand={d}\n",
        .{ i, instr.op, instr.rd, instr.rs1, instr.operand });
}
```

## 3. Common ARM64 Encoding Pitfalls

### CSET/CSINC: Rn field must be WZR (31)

`CSET Wd, cond` = `CSINC Wd, WZR, WZR, inv(cond)`.
Both Rn (bits 9-5) and Rm (bits 20-16) must be 31 (WZR).
If Rn=0 instead of 31, CSINC reads W0 (regs pointer) instead of zero.

Correct base: `0x1A9F07E0` (32-bit), `0x9A9F07E0` (64-bit).
Wrong base:   `0x1A9F0400` (Rn=0 instead of 31).

### Verify encodings with objdump

Encode a single instruction and check:
```python
import struct
with open('/tmp/test.bin','wb') as f:
    f.write(struct.pack('<I', 0x1A9FC7E8))  # CSET W8, le
# wrap in ELF and disassemble
```

### STP/LDP pre/post-index: imm7 in units of 8

`stpPre(rt1, rt2, SP, -2)` means offset = -2 * 8 = -16 bytes.

## 4. Branch Offset Debugging

Branch targets use RegInstr PC (not loop iteration index).
When instructions consume data words (e.g., CALL + NOP), the pc_map
must be indexed by actual RegInstr PC, not iteration count.

### pc_map strategy

Pre-allocate `ir.len + 1` entries. Set `pc_map[pc]` at each RegInstr
start. Data words consumed by handlers leave their slots as 0 (no
branches target them).

## 5. Cross-Module JIT Cleanup

When copying functions between stores (imports), reset all cached
JIT state (jit_code, jit_failed, call_count) to prevent double-free.

## 6. Profile vs JIT

Skip JIT compilation and dispatch when profiling is active
(`self.profile != null`) to ensure opcode counters are updated.
