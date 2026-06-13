;; D-324 — memory.copy on an i64-indexed memory with dst >= 2^32 must
;; trap OutOfBounds. A handler popping/capturing the address at i32
;; width reads the low 32 bits (= 0) and silently copies instead.
(module
  (memory i64 1)
  (func (export "test") (result i32)
    i64.const 0x100000000
    i64.const 0
    i64.const 1
    memory.copy
    i32.const 1))
