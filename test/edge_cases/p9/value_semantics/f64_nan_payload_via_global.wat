;; ADR-0110 Phase A.2 boundary fixture — Value-layer f64 NaN
;; payload preservation through global.set/get round-trip.
;;
;; Stress axis: numeric range (FP special — NaN payload per Wasm
;; §6.2.3). Stores a non-canonical NaN (sign=0, exp=all-ones,
;; mantissa = 0x8_DEAD_BEEF_F00D) via f64.reinterpret_i64 to
;; bypass any constant-folding canonicalisation, then asserts the
;; payload bits survive the round-trip through Value.bits64 /
;; `.f64`. Returns 1 if preserved bit-exact, 0 otherwise.
;;
;; Behaviour-preservation contract for §9.13-V Phase A.4 cascade.
;; Critical because the Value union's `.f64` and `.bits64` aliasing
;; semantics are exactly what Phase A.4a's storage layout edit
;; could regress if union variant order changes during the widen.
(module
  (global $g (mut f64) (f64.const 0))
  (func (export "test") (result i32)
    (global.set $g (f64.reinterpret_i64 (i64.const 0x7FF8DEADBEEFF00D)))
    (i64.eq
      (i64.reinterpret_f64 (global.get $g))
      (i64.const 0x7FF8DEADBEEFF00D))))
