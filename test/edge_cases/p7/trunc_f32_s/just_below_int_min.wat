;; Boundary: i32.trunc_f32_s with src = next-f32-below INT32_MIN
;; (= -2147483904.0f, hex 0xCF000001). trunc(src) = -2147483904
;; which doesn't fit in i32; spec requires trap.
;;
;; Provenance: sub-h3a (commit c29b243) — this is exactly the
;; condition `lo_cmp = .le` at lo = 0xCF000001 catches.
(module
  (func (export "test") (result i32)
    f32.const -2147483904.0
    i32.trunc_f32_s))
