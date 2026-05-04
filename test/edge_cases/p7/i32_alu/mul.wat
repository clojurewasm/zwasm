;; Boundary: i32.mul. Verifies sub-b1's mul emit.
(module
  (func (export "test") (result i32)
    i32.const 6
    i32.const 7
    i32.mul))
