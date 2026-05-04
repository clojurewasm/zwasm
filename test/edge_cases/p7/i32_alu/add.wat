;; Boundary: i32.add through full JIT pipeline.
;; Validates sub-b1's emit + sub-7.5a/b/c integration.
(module
  (func (export "test") (result i32)
    i32.const 7
    i32.const 5
    i32.add))
