;; i64.atomic.load32_u (0xFE 0x16) — 4B zero-extend to i64; wrap to i32.
(module (memory 1)
  (func (export "test") (result i32)
    (i32.store (i32.const 8) (i32.const 0x12345678))
    (i32.wrap_i64 (i64.atomic.load32_u (i32.const 8)))))
