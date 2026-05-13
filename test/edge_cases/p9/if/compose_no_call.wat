;; D-093 (d-15) probe: compose-of-2 single-result if WITHOUT
;; intermediate call ops. Confirms whether the as-compare-operand
;; failure mode requires the call-clobber of caller-saved regs.
;;
;; Returns gt(if_a, if_b) where if_a returns 3 (then-arm), if_b
;; returns 4 (then-arm). gt(3, 4) = 0.
(module
  (func (export "test") (result i32)
    (f32.gt
      (if (result f32) (i32.const 1)
        (then (f32.const 3))
        (else (f32.const -3)))
      (if (result f32) (i32.const 0)
        (then (f32.const 4))
        (else (f32.const -4))))))
