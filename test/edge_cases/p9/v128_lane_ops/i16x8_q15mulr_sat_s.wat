;; §15.4 / D-246 residual chunk B boundary fixture — i16x8.q15mulr_sat_s
;; (arm64 SQRDMULH .8H). Q15 signed rounding doubling multiply, high half.
;; result[i] = sat_s16((a*b + 0x4000) >> 15), Q15 fixed-point.
;; lane0: a=0x4000(16384=0.5), b=0x4000 -> (16384*16384 + 0x4000)>>15
;;        = (0x10000000 + 0x4000) >> 15 = 0x2000 = 8192 (= 0.5*0.5=0.25 in Q15).
;; lane1: a=-32768(-1.0), b=-32768 -> (0x40000000 + 0x4000) >> 15 = 0x8000,
;;        which saturates to +32767 (the canonical Q15 -1.0*-1.0 overflow case).
;; Returns 1 iff lane0 == 8192 AND lane1 == 32767.
(module
  (func (export "test") (result i32)
    (local $r v128)
    (local.set $r
      (i16x8.q15mulr_sat_s
        (v128.const i16x8 16384 -32768 0 0 0 0 0 0)
        (v128.const i16x8 16384 -32768 0 0 0 0 0 0)))
    (i32.and
      (i32.eq (i16x8.extract_lane_s 0 (local.get $r)) (i32.const 8192))
      (i32.eq (i16x8.extract_lane_s 1 (local.get $r)) (i32.const 32767)))))
