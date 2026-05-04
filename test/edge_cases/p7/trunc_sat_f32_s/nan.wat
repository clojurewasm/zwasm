;; Boundary: i32.trunc_sat_f32_s with src = NaN. Wasm 2.0 sat
;; semantics: NaN → 0 (NOT trap). ARM64 FCVTZS naturally produces
;; 0 for NaN; sub-h5 verifies this with no extra check.
(module
  (func (export "test") (result i32)
    f32.const nan
    i32.trunc_sat_f32_s))
