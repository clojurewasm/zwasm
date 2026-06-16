;; D-305 coverage: a `(list u64)` across the boundary — tests the 8-byte element
;; / align-8 path (vs listu32's 4-byte), exercising the generic elem_size copy.
;; B.firstelem(xs:list<u64>)->u32 = low 32 bits of xs[0]; A builds
;; [0x1122334455667788] → expects 0x55667788 (1432778632).
(component
  (component $B
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (local $p i32) (local.set $p (global.get $bump))
        (global.set $bump (i32.add (global.get $bump) (local.get 3))) (local.get $p)))
    (core instance $blibc (instantiate $libc))
    (core module $MB
      (import "libc" "mem" (memory 1))
      (func (export "firstelem") (param $ptr i32) (param $len i32) (result i32)
        (i32.wrap_i64 (i64.load (local.get $ptr)))))
    (core instance $ib (instantiate $MB (with "libc" (instance $blibc))))
    (func (export "firstelem") (param "xs" (list u64)) (result u32)
      (canon lift (core func $ib "firstelem")
        (memory $blibc "mem") (realloc (func $blibc "cabi_realloc")))))
  (component $A
    (import "firstelem" (func $fe (param "xs" (list u64)) (result u32)))
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (local $p i32) (local.set $p (global.get $bump))
        (global.set $bump (i32.add (global.get $bump) (local.get 3))) (local.get $p)))
    (core instance $alibc (instantiate $libc))
    (core func $fe_core (canon lower (func $fe)
      (memory $alibc "mem") (realloc (func $alibc "cabi_realloc"))))
    (core module $MA
      (import "deps" "firstelem" (func $fe (param i32 i32) (result i32)))
      (import "libc" "mem" (memory 1))
      (func (export "run") (result i32)
        (i64.store (i32.const 16) (i64.const 0x1122334455667788))
        (call $fe (i32.const 16) (i32.const 1))))
    (core instance $deps (export "firstelem" (func $fe_core)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps)) (with "libc" (instance $alibc))))
    (func (export "run") (result u32) (canon lift (core func $ia "run"))))
  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "firstelem" (func $b "firstelem"))))
  (export "run" (func $a "run")))
