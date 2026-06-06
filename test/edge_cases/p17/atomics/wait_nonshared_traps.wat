;; memory.atomic.wait32 on a NON-shared memory → trap (ExpectedSharedMemory).
(module (memory 1)
  (func (export "test") (result i32)
    (memory.atomic.wait32 (i32.const 12) (i32.const 0) (i64.const -1))))
