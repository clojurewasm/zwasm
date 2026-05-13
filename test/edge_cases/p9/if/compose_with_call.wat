;; D-093 (d-16) / D-095 / ADR-0060: regalloc force-spill for
;; call-crossing vregs. Compose-of-two if(result f32) with a
;; `call $dummy` inside each arm. Without the d-16 fix, the
;; outer compose's first vreg (= if_a's f32.const 3 = 3.0) lands
;; on a caller-saved register and gets clobbered by the inner
;; calls (typically to 0 = the call's i32-return-class scratch).
;; f32.gt(clobbered ≈ 0, 2) = 0, but f32.gt(3, 2) = 1 — the
;; mismatch is the diagnostic. The d-16 force-spill mechanism
;; carries V_a through the calls via the spill region.
;;
;; if_a = 3 (then-arm), if_b = 2 (then-arm). gt(3, 2) = 1.
(module
  (func $dummy)
  (func (export "test") (result i32)
    (f32.gt
      (if (result f32) (i32.const 1)
        (then (call $dummy) (f32.const 3))
        (else (call $dummy) (f32.const -3)))
      (if (result f32) (i32.const 1)
        (then (call $dummy) (f32.const 2))
        (else (call $dummy) (f32.const -2))))))
