;; Boundary: i32.trunc_f32_s with src = 2^31 = 2147483648.0f
;; (hex 0x4F000000). INT32_MAX = 2^31 - 1 doesn't fit src exactly,
;; so 2^31 represents the smallest f32 strictly greater than
;; INT32_MAX; spec requires trap.
;;
;; Provenance: sub-h3a — the upper-bound check at hi = 0x4F000000
;; with `cmp = .ge` traps here.
(module
  (func (export "test") (result i32)
    f32.const 2147483648.0
    i32.trunc_f32_s))
