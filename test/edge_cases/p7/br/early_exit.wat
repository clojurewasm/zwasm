;; Boundary: br to exit a block early.
;; Tests sub-7.5c-iv's branch handling — block produces 5
;; via early br, falling-through dead code (i32.const 99)
;; never executes.
(module
  (func (export "test") (result i32)
    (block (result i32)
      i32.const 5
      br 0
      i32.const 99)))
