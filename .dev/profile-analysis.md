# Benchmark Profile Analysis

Baseline measurements and opcode frequency analysis for register IR design.
All measurements: ReleaseSafe, ARM64 Mac (M-series).

## Baseline Times

| Benchmark     | Params       | Time    | Instructions | Calls     | Instrs/ms |
|---------------|-------------|---------|-------------|-----------|-----------|
| fib           | 35          | 568ms   | 238.9M      | 29.9M     | 420K      |
| tak           | 24, 16, 8   | 49ms    | 18.1M       | 2.5M      | 369K      |
| sieve         | 1,000,000   | 49ms    | 30.1M       | 1         | 614K      |
| nbody         | 1,000,000   | 195ms   | 143.0M      | 3         | 733K      |
| nqueens       | 8           | ~1ms    | 1.1M        | 17.8K     | ~1100K    |

## Workload Categories

### Recursive Integer (fib, tak)
- **Call overhead**: 12-14% of instructions are `call`
- **Stack traffic**: local.get/set + super variants = ~31%
- **Control flow**: end/if/else = ~37%
- **Compute**: i32.add/sub/le_s = ~25%
- **Memory access**: none

### Loop + Memory (sieve)
- **Loop control**: br_if + br = 27.4%
- **Memory ops**: i32.store8 + i32.load8_u = 13.7%
- **Stack traffic**: local.set (14%), locals+gt_s (13.7%)
- **No calls**: single function, all loop-based
- **Highest instrs/ms**: simpler opcode mix, less overhead

### Float-Heavy (nbody)
- **Float ops**: f64.mul (15.4%) + f64.add (7.7%) + f64.sub (4.2%) + f64.sqrt (0.7%) + f64.div (0.7%) = 28.0%
- **Memory ops**: f64.load (16.8%) + f64.store (8.4%) = 25.2%
- **Constants as offsets**: i32.const = 21.0% (memory addressing)
- **No calls**: single loop body
- **Highest throughput per instruction**: 733K instrs/ms

### Mixed Integer + Memory (nqueens)
- **Super instrs dominant**: locals+sub (13.4%), local.get+get (9.8%)
- **Comparison-heavy**: i32.eq (11.0%), i32.ge_s (4.3%)
- **Memory**: i32.load (4.1%), i32.store (0.2%)
- **Moderate calls**: 1.6%

## Key Bottleneck Patterns

### 1. Stack Traffic (Target: Register IR)
local.get/set and their super-instruction variants account for 30-50% of all
instructions across all workloads. Register IR eliminates this overhead entirely
by mapping Wasm locals to virtual registers.

**Expected impact**: 2-3x speedup for recursive integer (fib, tak).
Moderate for loop-heavy (sieve, nbody) since they already have fewer locals.

### 2. Control Flow Overhead
end/block/loop/if/else/br account for 30-40% in recursive benchmarks.
In register IR, many become implicit (blocks have no runtime cost, labels
are just branch targets).

### 3. Memory Access Patterns
- sieve: byte-level (i32.load8_u/store8) — cache-friendly sequential
- nbody: f64 loads/stores with constant offsets — could fuse offset calculation
- nqueens: i32 loads — indexed array access

Register IR can pre-compute constant memory offsets, reducing i32.const
overhead (21% of nbody instructions).

### 4. Function Call Overhead
fib/tak spend 12-14% on call instructions. Each call involves:
- Frame push (locals_start, return_arity, etc.)
- Operand stack manipulation
- Label push
- IR predecoding check

Inlining hot recursive functions would help, but is a later optimization.

### 5. Super Instructions Already Help
The predecoder fuses 2-3 opcode sequences (local.get+const, locals+add, etc.).
These reduce dispatch overhead but still use the operand stack.
Register IR subsumes super instructions by eliminating the stack entirely.

## Register IR Design Implications

1. **Map locals to virtual registers** — eliminates the biggest bottleneck
2. **Implicit block/end** — control flow becomes branch targets only
3. **Constant folding** — i32.const used as memory offsets can be folded
4. **f64 register allocation matters** — nbody is 28% float compute
5. **Memory offset fusion** — fold constant offsets into load/store instructions
6. **Call convention**: pass args in registers, not on operand stack
