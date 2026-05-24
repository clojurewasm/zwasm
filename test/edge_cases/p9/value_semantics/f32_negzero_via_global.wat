;; ADR-0110 Phase A.2 boundary fixture — Value-layer f32 ±0
;; distinguishability through global.set/get round-trip.
;;
;; Stress axis: numeric range (FP special — sign-bit preservation
;; on f32 zero). -0.0 (0x80000000) != +0.0 (0x00000000). The
;; Value union's `.f32` variant is 32-bit; the upper 32 bits of
;; the 8-byte slot are unobservable from the f32 path. A
;; Phase A.4 widen that mis-clears the upper bits could shift
;; subsequent f32 reads — this fixture's contract guards the
;; low 32 bits specifically.
(module
  (global $g (mut f32) (f32.const 0))
  (func (export "test") (result i32)
    (global.set $g (f32.const -0))
    (i32.eq
      (i32.reinterpret_f32 (global.get $g))
      (i32.const 0x80000000))))
