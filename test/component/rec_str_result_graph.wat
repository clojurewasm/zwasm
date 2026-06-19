;; D-305(b4) RECORD-WITH-STRING result across a 2-component boundary.
;; B exports mk() -> info, info = record{msg:string, n:u32}, returning {msg:"hi", n:5}.
;; A calls mk() and exports run() -> n + first_byte(msg) = 5 + 'h'(104) = 109.
;;
;; The record has an INTERNAL pointer (the string), so unlike a flat record it
;; can't cross by raw byte copy — the boundary canon.load's it from B's memory
;; then canon.store's it into A's retptr, lowering "hi" into A's OWN memory via
;; A's cabi_realloc (A-relative pointer). A reading the first byte at that pointer
;; proves the string bytes physically crossed. Canonical in-memory layout of
;; record{string,u32}: msg_ptr@0, msg_len@4, n@8. Both lift/lower need
;; (memory)+(realloc). Nominal record type crosses via export/import + alias.
(component
  (component $B
    (type $info (record (field "msg" string) (field "n" u32)))
    (export $pe "info" (type $info))
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (global.get $bump)
        (global.set $bump (i32.add (global.get $bump) (local.get 3)))))
    (core instance $blibc (instantiate $libc))
    (core module $MB
      (import "libc" "mem" (memory 1))
      (func (export "mk") (result i32)
        ;; "hi" bytes at offset 100
        (i32.store8 (i32.const 100) (i32.const 104))
        (i32.store8 (i32.const 101) (i32.const 105))
        ;; record at offset 8: msg_ptr=100, msg_len=2, n=5
        (i32.store (i32.const 8) (i32.const 100))
        (i32.store offset=4 (i32.const 8) (i32.const 2))
        (i32.store offset=8 (i32.const 8) (i32.const 5))
        (i32.const 8)))
    (core instance $ib (instantiate $MB (with "libc" (instance $blibc))))
    (func $f (result $pe)
      (canon lift (core func $ib "mk")
        (memory $blibc "mem") (realloc (func $blibc "cabi_realloc"))))
    (export "mk" (func $f)))
  (component $A
    (type $info (record (field "msg" string) (field "n" u32)))
    (import "info" (type $pe (eq $info)))
    (import "mk" (func $mk (result $pe)))
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (global.get $bump)
        (global.set $bump (i32.add (global.get $bump) (local.get 3)))))
    (core instance $alibc (instantiate $libc))
    (core func $mk_core (canon lower (func $mk)
      (memory $alibc "mem") (realloc (func $alibc "cabi_realloc"))))
    (core module $MA
      (import "deps" "mk" (func $mk (param i32)))
      (import "libc" "mem" (memory 1))
      (func (export "run") (result i32)
        (call $mk (i32.const 128))
        ;; n (@128+8) + first byte of msg (@ msg_ptr stored at 128)
        (i32.add
          (i32.load offset=8 (i32.const 128))
          (i32.load8_u (i32.load (i32.const 128))))))
    (core instance $deps (export "mk" (func $mk_core)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps)) (with "libc" (instance $alibc))))
    (func (export "run") (result u32)
      (canon lift (core func $ia "run"))))
  (instance $b (instantiate $B))
  (alias export $b "info" (type $bp))
  (instance $a (instantiate $A
    (with "info" (type $bp))
    (with "mk" (func $b "mk"))))
  (export "run" (func $a "run")))
