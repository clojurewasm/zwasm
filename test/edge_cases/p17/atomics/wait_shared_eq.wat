;; wait32 on shared mem, value(42) == expected(42) → 2 (timed-out single-thread).
(module (memory 1 1 shared)
  (func (export "test") (result i32)
    (i32.atomic.store (i32.const 12) (i32.const 42))
    (memory.atomic.wait32 (i32.const 12) (i32.const 42) (i64.const -1))))
