;; D-305 RED fixture: a 2-component graph that passes a STRING across the
;; component boundary (the gap beyond adder_graph's flat-u32). Component B
;; exports `firstbyte(s: string) -> u32` returning s[0] — it READS the bytes, so
;; a correct result REQUIRES the string to be marshalled A-memory → B-memory at
;; the boundary, not just pass A's (ptr,len) through. Component A builds "Z"
;; (0x5A) in its own memory and calls firstbyte → must get 0x5A. Today the
;; cross-component call has no boundary lift/lower of aggregates, so this traps
;; or returns the wrong byte → RED. Each component uses a separate $libc core
;; module (memory + cabi_realloc) so the canon lower can reference a memory that
;; exists BEFORE the main module instance (no definition cycle).
(component
  ;; ---- child B: firstbyte(s: string) -> u32 = s[0] ----
  (component $B
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (local $p i32)
        (local.set $p (global.get $bump))
        (global.set $bump (i32.add (global.get $bump) (local.get 3)))
        (local.get $p)))
    (core instance $blibc (instantiate $libc))
    (core module $MB
      (import "libc" "mem" (memory 1))
      (func (export "firstbyte") (param $ptr i32) (param $len i32) (result i32)
        (i32.load8_u (local.get $ptr))))   ;; reads B's OWN memory at ptr
    (core instance $ib (instantiate $MB (with "libc" (instance $blibc))))
    (func (export "firstbyte") (param "s" string) (result u32)
      (canon lift (core func $ib "firstbyte")
        (memory $blibc "mem") (realloc (func $blibc "cabi_realloc")))))

  ;; ---- child A: imports firstbyte, exports run() -> u32 ----
  (component $A
    (import "firstbyte" (func $fb (param "s" string) (result u32)))
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (local $p i32)
        (local.set $p (global.get $bump))
        (global.set $bump (i32.add (global.get $bump) (local.get 3)))
        (local.get $p)))
    (core instance $alibc (instantiate $libc))
    (core func $fb_core (canon lower (func $fb)
      (memory $alibc "mem") (realloc (func $alibc "cabi_realloc"))))
    (core module $MA
      (import "deps" "firstbyte" (func $fb (param i32 i32) (result i32)))
      (import "libc" "mem" (memory 1))
      (func (export "run") (result i32)
        (i32.store8 (i32.const 16) (i32.const 0x5A))   ;; "Z" at mem[16]
        (call $fb (i32.const 16) (i32.const 1))))       ;; firstbyte("Z") → 0x5A
    (core instance $deps (export "firstbyte" (func $fb_core)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps)) (with "libc" (instance $alibc))))
    (func (export "run") (result u32)
      (canon lift (core func $ia "run"))))

  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "firstbyte" (func $b "firstbyte"))))
  (export "run" (func $a "run")))
