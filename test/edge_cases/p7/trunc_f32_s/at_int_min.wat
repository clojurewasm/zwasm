;; Boundary: i32.trunc_f32_s with src = -2^31 exactly.
;; Provenance: derived from sub-h3a's f32-source bounds; -2147483648.0f
;; is exactly representable in f32 (0xCF000000) and IS the smallest
;; valid INT32. trunc(src) = INT32_MIN, fits in i32, no trap.
;;
;; Cross-check: wasm-1.0 spec testsuite `conversions.wast` line range
;; covers similar but uses different src values; this fixture
;; specifically pins the edge.
(module
  (func (export "test") (result i32)
    f32.const -2147483648.0
    i32.trunc_f32_s))
