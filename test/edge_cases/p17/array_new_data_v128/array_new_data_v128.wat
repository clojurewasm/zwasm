;; D-493: array.new_data with a v128 element type (16-byte natural width).
;; Wasm GC §array.new_data admits numtype OR vectype; the prior u64-pack
;; copy loop overflowed at nat=16 → now a zero-slot + memcpy(nat) path.
;; SIMD is JIT-only (interp traps on array.get-v128), so this runs under
;; the edge-runner's JIT. 2 v128 elements; element 1 lane 0 = 2.
(module
  (type $a (array (mut v128)))
  (data $d "\01\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\02\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")
  (func (export "test") (result i32)
    (local $arr (ref $a))
    (local.set $arr (array.new_data $a $d (i32.const 0) (i32.const 2)))
    (i32x4.extract_lane 0 (array.get $a (local.get $arr) (i32.const 1)))))
