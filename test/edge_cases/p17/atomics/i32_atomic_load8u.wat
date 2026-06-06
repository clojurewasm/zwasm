;; i32.atomic.load8_u (0xFE 0x12) — byte access, always aligned.
(module (memory 1)
  (func (export "test") (result i32)
    (i32.store8 (i32.const 5) (i32.const 0xAB))
    (i32.atomic.load8_u (i32.const 5))))
