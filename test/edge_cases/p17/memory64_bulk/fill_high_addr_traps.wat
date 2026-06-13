;; D-324 — memory.fill twin of copy_high_addr_traps.
(module
  (memory i64 1)
  (func (export "test") (result i32)
    i64.const 0x100000000
    i32.const 0xAB
    i64.const 1
    memory.fill
    i32.const 1))
