;; Wasm 3.0 GC: array.copy of a region onto itself (same array, identical
;; src/dst offset) must be alias-safe — memmove semantics (§3.3.5.6.14).
;;
;; Regression (ADR-0192, wasmtime gc misc_testsuite): both the interp
;; handler (array_ops.zig arrayCopy) and the JIT trampoline helper
;; (jit_abi.zig jitGcArrayCopy) used per-element `@memcpy`, which panics
;; "@memcpy arguments alias" when dst_off == src_off on the same array
;; (the two slices are identical). The synthetic spec gc suite (362/0)
;; never exercised a self-region copy; wasmtime's corpus does.
;;
;; Stress axes (test_discipline.md §1): GC array bulk op × aliasing/overlap
;; boundary. Seeds [10,20,30,40]; self-copies slots [1..3) onto themselves
;; (identity); returns a[1], which must stay 20.
;;
;; Provenance: minimal reduction of wasmtime tests/misc_testsuite/gc/
;; array-copy-inline.wast; assembled with wasm-tools parse.
(module
  (type $arr (array (mut i32)))
  (func (export "test") (result i32)
    (local $a (ref $arr))
    (local.set $a (array.new_default $arr (i32.const 4)))
    (array.set $arr (local.get $a) (i32.const 0) (i32.const 10))
    (array.set $arr (local.get $a) (i32.const 1) (i32.const 20))
    (array.set $arr (local.get $a) (i32.const 2) (i32.const 30))
    (array.set $arr (local.get $a) (i32.const 3) (i32.const 40))
    ;; self-region copy: dst_off == src_off == 1, len 2 (identity).
    (array.copy $arr $arr
      (local.get $a) (i32.const 1)
      (local.get $a) (i32.const 1)
      (i32.const 2))
    (array.get $arr (local.get $a) (i32.const 1))))
