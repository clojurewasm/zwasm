;; §15.4 / D-246 residual chunk B boundary fixture —
;; i16x8.extadd_pairwise_i8x16_s (arm64 SADDLP .8H<-.16B).
;; Stress axis: signed adjacent-pair widening add (1-src misc).
;; A = i8x16 [1,2, 3,4, 100,100, -1,-2, 0,0, 0,0, 0,0, 0,0].
;; result i16x8 lane k = A[2k] + A[2k+1] (sign-extended):
;;   lane0 = 1+2 = 3
;;   lane2 = 100+100 = 200 (would overflow i8 but widened to i16)
;;   lane3 = -1+-2 = -3
;; Returns 1 iff lane0==3 AND lane2==200 AND lane3==-3.
(module
  (func (export "test") (result i32)
    (local $r v128)
    (local.set $r
      (i16x8.extadd_pairwise_i8x16_s
        (v128.const i8x16 1 2 3 4 100 100 -1 -2 0 0 0 0 0 0 0 0)))
    (i32.and
      (i32.and
        (i32.eq (i16x8.extract_lane_s 0 (local.get $r)) (i32.const 3))
        (i32.eq (i16x8.extract_lane_s 2 (local.get $r)) (i32.const 200)))
      (i32.eq (i16x8.extract_lane_s 3 (local.get $r)) (i32.const -3)))))
