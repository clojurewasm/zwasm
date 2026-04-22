# JIT Debugging Techniques

Reference for debugging ARM64 JIT code generation issues.

## 1. Dump & Disassemble Generated Machine Code

The most effective technique. Dump the mmap'd buffer to a binary file,
wrap in a minimal ELF, and disassemble with LLVM objdump.

### Dump from `finalize()` in jit.zig

```zig
// Add temporarily in Compiler.finalize(), after @memcpy:
if (condition) { // e.g. self.reg_count == 11
    const file = std.Io.Dir.cwd().createFile("/tmp/jit_dump.bin", .{}) catch null;
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

## 5. FP Cache Eviction at Branch Target Merge Points

When control flow merges (if/else join, loop entry), the FP D-register
cache must be evicted. The eviction code must be placed BEFORE the
`pc_map` entry so that:
- **Fall-through paths** execute the eviction (they flow through it naturally)
- **Branch targets** skip it (branches use `pc_map` to jump AFTER eviction)

Wrong order (old bug):
```
pc_map[pc] = currentIdx()   // branches land HERE
fpCacheEvictAll()            // fall-through evicts, but branches also hit this
```

Correct order:
```
fpCacheEvictAll()            // fall-through evicts
pc_map[pc] = currentIdx()   // branches land HERE (after eviction)
```

**Symptom**: Base-case results corrupted by stale D-register values from
the other branch path. Example: f64 recursive factorial base case returned
garbage because `fmov x8, d4` from the else-path's f64.mul was executed
when branching to the merge point.

**General principle**: Any per-merge-point fixup code (cache eviction,
register state normalization) must go BEFORE the branch target label,
never after. Branches skip fixup; fall-through executes it.

## 6. Cross-Module JIT Cleanup

When copying functions between stores (imports), reset all cached
JIT state (jit_code, jit_failed, call_count) to prevent double-free.

## 7. Profile vs JIT

Skip JIT compilation and dispatch when profiling is active
(`self.profile != null`) to ensure opcode counters are updated.

## 8. SIMD JIT (Phase 13)

### v128 Storage Model
v128 values stored as regs[vreg] (lower 64 bits) + Vm.simd_hi[vreg] (upper 64 bits).
Non-contiguous → every SIMD op needs 3-instruction load and 3-instruction store:
```
Load:  LDR Dd [REGS_PTR, #vreg*8] + LDR X8 [VM, #simd_hi+vreg*8] + INS Vd.D[1] X8
Store: STR Dd [REGS_PTR, #vreg*8] + UMOV X8 Vd.D[1] + STR X8 [VM, #simd_hi+vreg*8]
```
Binary op total: 10 instructions (vs wasmtime's 1). This is the main gap source.
Future: contiguous v128 storage or NEON register allocation would eliminate this.

### v128.load/store and Guard Pages
Native v128.load/store uses explicit bounds check (addr+16 > mem_size),
NOT guard pages. Guard page signal handler correctly recognizes NEON LDR Q
within JIT code range, but explicit bounds check was chosen for consistency
and to avoid needing separate guard page integration for 128-bit loads.

### Trampoline Fallback
Unimplemented SIMD opcodes fall back to jitSimdTrampoline (vm.zig).
Trampoline marshals regs[]/simd_hi[] ↔ op_stack and calls executeSimdIR.
Per-instruction C function call overhead — acceptable for rare ops,
but hot loops need native codegen.

### OP_MOV and simd_hi
OP_MOV must copy simd_hi[rd] = simd_hi[rs1] for v128 correctness.
OP_CONST32/64 must clear simd_hi[rd] = 0 to prevent stale upper bits.
Bug found 2026-03-22: upper 64 bits lost through OP_MOV (fixed).
