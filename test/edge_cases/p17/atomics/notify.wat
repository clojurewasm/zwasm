;; memory.atomic.notify (0xFE 0x00) — single-thread → 0 waiters woken.
(module (memory 1)
  (func (export "test") (result i32)
    (memory.atomic.notify (i32.const 12) (i32.const 1))))
