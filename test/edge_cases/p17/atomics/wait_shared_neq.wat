;; wait32 on shared mem, value(42) != expected(99) → 1 (not-equal).
(module (memory 1 1 shared)
  (func (export "test") (result i32)
    (i32.atomic.store (i32.const 12) (i32.const 42))
    (memory.atomic.wait32 (i32.const 12) (i32.const 99) (i64.const 0))))
