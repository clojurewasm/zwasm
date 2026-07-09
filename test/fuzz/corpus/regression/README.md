# Differential-fuzz regression corpus (D-510)

Committed `.wasm` modules replayed by `zwasm-fuzz-exec` on every
`zig build fuzz-diff` / `test-fuzz-exec` / `test-all` run (the
wazero-`fuzzcases` pattern). Two kinds of entries:

1. **Minimised past findings** — when a fuzz campaign or the differential
   gate surfaces a real interp-vs-JIT divergence, `wasm-tools shrink` the
   trigger module and land it here in the same PR as the fix.
2. **Hand-written exercisers** for comparison dimensions the `exec_seed`
   corpus does not reach (it is pure-compute).

Modules must be self-contained (no imports) and expose 0-param /
single-scalar-result exports — the harness's comparable shape. Only `.wasm`
files are loaded; regenerate from the sources below with
`wasm-tools parse` (Mac gen shell; test hosts are toolchain-free).

## Current entries

### `mem_store_pattern.wasm`

Memory-writing comparator — makes the post-invoke memory-snapshot compare
non-vacuous, and pins the widest in-bounds access adjacent to the page
boundary under both bounds modes (ADR-0202).

```wat
(module
  (memory 1)
  ;; Fill bytes [0,256) with (i*7)&0xff, then return the byte sum (32640).
  (func (export "fill_and_sum") (result i32)
    (local $i i32) (local $sum i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
        (i32.store8 (local.get $i) (i32.mul (local.get $i) (i32.const 7)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.set $i (i32.const 0))
    (block $done2
      (loop $l2
        (br_if $done2 (i32.ge_u (local.get $i) (i32.const 256)))
        (local.set $sum (i32.add (local.get $sum) (i32.load8_u (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l2)))
    (local.get $sum))
  ;; i64 store into the last 8 in-bounds bytes; read back the high half
  ;; (0x11223344).
  (func (export "store_near_end") (result i32)
    (i64.store (i32.const 65528) (i64.const 0x1122334455667788))
    (i32.load (i32.const 65532))))
```

### `oob_guard_boundary.wasm`

Boundary-straddling accesses — under the default `.auto` mode the JIT elides
the inline bounds check (ADR-0202 guard-page elision) and must trap via the
guard-fault → PC-redirect path with the same precise `oob_memory` kind as the
interp and the `.explicit` lane. `exec_seed/oob_trap.wasm` uses a far-oob
address; these straddle the page end by 1–2 bytes (the elision's edge case).

```wat
(module
  (memory 1)
  ;; 4-byte load at 65533: bytes 65533..65537 cross the 65536 end → trap.
  (func (export "oob_load_straddle") (result i32)
    (i32.load (i32.const 65533)))
  ;; 4-byte store at 65534 → trap; must write NO byte.
  (func (export "oob_store_straddle") (result i32)
    (i32.store (i32.const 65534) (i32.const 42))
    (i32.const 0))
  ;; Last fully in-bounds 4-byte slot — must NOT trap on any lane.
  (func (export "load_last_slot") (result i32)
    (i32.load (i32.const 65532))))
```
