;; Boundary: if/then/else with cond=1 (then arm), block-result.
;; Tests sub-7.5c-vi's D-027 merge-aware label-stack fix —
;; both arms' results converge on the THEN arm's home register,
;; so post-if reads the correctly-merged value.
(module
  (func (export "test") (result i32)
    (if (result i32) (i32.const 1)
      (then (i32.const 11))
      (else (i32.const 22)))))
