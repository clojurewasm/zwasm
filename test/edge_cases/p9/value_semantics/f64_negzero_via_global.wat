;; ADR-0110 Phase A.2 boundary fixture — Value-layer f64 ±0
;; distinguishability through global.set/get round-trip.
;;
;; Stress axis: numeric range (FP special — sign-bit preservation
;; on zero). -0.0 (bit pattern 0x8000000000000000) != +0.0
;; (0x0000000000000000); the IEEE-754 sign bit is the only
;; observable distinction. A Value-layer reset-to-zero bug
;; (e.g. wrong @memset literal during Phase A.4a init refactor)
;; would surface as -0 silently flipping to +0. Returns 1 if -0
;; bit pattern preserved, 0 otherwise.
(module
  (global $g (mut f64) (f64.const 0))
  (func (export "test") (result i32)
    (global.set $g (f64.const -0))
    (i64.eq
      (i64.reinterpret_f64 (global.get $g))
      (i64.const 0x8000000000000000))))
