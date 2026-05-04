;; Boundary: i32.sub producing a negative result.
;; 5 - 7 = -2 (= 0xFFFFFFFE as u32). Validates sub-b1's
;; sub-emit + the runner's signed/unsigned i32 handling.
(module
  (func (export "test") (result i32)
    i32.const 5
    i32.const 7
    i32.sub))
