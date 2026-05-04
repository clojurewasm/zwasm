;; Boundary: if/then/else with cond=0 (else arm), block-result.
;; Verifies the same merge fix from then_branch.wat — the else
;; arm's result is MOVed into the then arm's reg at the if-end.
(module
  (func (export "test") (result i32)
    (if (result i32) (i32.const 0)
      (then (i32.const 11))
      (else (i32.const 22)))))
