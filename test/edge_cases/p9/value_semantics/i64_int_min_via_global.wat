;; ADR-0110 Phase A.2 boundary fixture — Value-layer i64 INT_MIN
;; round-trip through global.set/get.
;;
;; Stress axis: numeric range (i64 INT_MIN — high-bit sign extension
;; through Value's 8-byte slot per Wasm §2.3 numeric types). The
;; constant 0x8000000000000000 is the largest negative i64 value.
;; A bit-level loss anywhere in the Value-layer marshal path
;; (global.set → operand stack → global.get) would surface as
;; mismatch. Returns 1 if round-trip is bit-exact, 0 otherwise.
;;
;; Behaviour-preservation contract for §9.13-V Phase A.4 cascade.
(module
  (global $g (mut i64) (i64.const 0))
  (func (export "test") (result i32)
    (global.set $g (i64.const -9223372036854775808))
    (i64.eq (global.get $g) (i64.const -9223372036854775808))))
