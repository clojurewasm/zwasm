;; D-305 aggregate-RESULT fixture: a 2-component graph that returns a STRING
;; across the component boundary (the gap beyond strlen_graph's string PARAM).
;; Component B exports `tag() -> string` returning the fixed 1-char string "Z"
;; (0x5A): it builds "Z" in its OWN libc memory via cabi_realloc and returns its
;; (ptr,len). A string result flattens to >1 core value, so per the Canonical
;; ABI it is returned via a RETPTR — B's core `tag` takes a retptr param and
;; writes (ptr,len) there. Component A imports `tag`, exports `run() -> u32`
;; that calls tag(), reads the FIRST BYTE of the returned string from A's OWN
;; memory, and returns it — which REQUIRES the result string be lowered
;; B-memory -> A-memory at the boundary (lift from B, lower into A), not B's
;; (ptr,len) passed through into foreign memory. Must yield 0x5A=90. Each
;; component uses a separate $libc core module (memory + cabi_realloc) so the
;; canon lower/lift can reference a memory that exists BEFORE the main module
;; instance (no definition cycle). Provenance: test/component/strlen_graph.wat.
(component
  ;; ---- child B: tag() -> string = "Z" ----
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
      (import "libc" "cabi_realloc" (func $realloc (param i32 i32 i32 i32) (result i32)))
      ;; Core ABI of a lifted `() -> string`: no value params, one retptr where
      ;; the (ptr,len) result pair is written. Build "Z" in B's own memory.
      (func (export "tag") (param $ret i32)
        (local $s i32)
        (local.set $s (call $realloc (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 1)))
        (i32.store8 (local.get $s) (i32.const 0x5A))   ;; "Z" into B's memory
        (i32.store (local.get $ret) (local.get $s))    ;; ret[0] = ptr
        (i32.store offset=4 (local.get $ret) (i32.const 1))))  ;; ret[1] = len
    (core instance $ib (instantiate $MB
      (with "libc" (instance $blibc))))
    (func (export "tag") (result string)
      (canon lift (core func $ib "tag")
        (memory $blibc "mem") (realloc (func $blibc "cabi_realloc")))))

  ;; ---- child A: imports tag, exports run() -> u32 ----
  (component $A
    (import "tag" (func $tag (result string)))
    (core module $libc
      (memory (export "mem") 1)
      (global $bump (mut i32) (i32.const 1024))
      (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
        (local $p i32)
        (local.set $p (global.get $bump))
        (global.set $bump (i32.add (global.get $bump) (local.get 3)))
        (local.get $p)))
    (core instance $alibc (instantiate $libc))
    (core func $tag_core (canon lower (func $tag)
      (memory $alibc "mem") (realloc (func $alibc "cabi_realloc"))))
    (core module $MA
      ;; The lowered import: no value params, one retptr (A's return area where
      ;; the boundary writes A-side (ptr,len)).
      (import "deps" "tag" (func $tag (param i32)))
      (import "libc" "mem" (memory 1))
      (func (export "run") (result i32)
        (call $tag (i32.const 256))               ;; ret-area at A.mem[256]
        (i32.load8_u (i32.load (i32.const 256))))) ;; first byte of A's string
    (core instance $deps (export "tag" (func $tag_core)))
    (core instance $ia (instantiate $MA
      (with "deps" (instance $deps)) (with "libc" (instance $alibc))))
    (func (export "run") (result u32)
      (canon lift (core func $ia "run"))))

  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "tag" (func $b "tag"))))
  (export "run" (func $a "run")))
