;; D-305(b) RECORD param across a 2-component boundary.
;; B exports sumrec(p: point) -> u32 = p.x + p.y, point = record{x:u32, y:u32}.
;; A calls sumrec({x:7,y:8}) and exports run() -> 15.
;;
;; KEY SPELLING RULE (wasm-tools 1.251): a named `record` used in an
;; imported/exported component func signature MUST be referenced through an
;; EXPORTED (or IMPORTED) type definition, not the raw type index. A bare
;; `(param "p" $point)` gives "func not valid to be used as export". You must
;; `(export $pe "point" (type $point))` then use `(param "p" $pe)`.
;; Records flatten structurally: a 2-u32 record PARAM = 2 direct core i32 words
;; (no memory/realloc needed); only the RESULT-record direction needs retptr.
(component
  (component $B
    (type $point (record (field "x" u32) (field "y" u32)))
    (export $pe "point" (type $point))
    (core module $MB
      (func (export "sumrec") (param i32 i32) (result i32)
        (i32.add (local.get 0) (local.get 1))))
    (core instance $ib (instantiate $MB))
    (func $f (param "p" $pe) (result u32)
      (canon lift (core func $ib "sumrec")))
    (export "sumrec" (func $f)))
  (component $A
    (type $point (record (field "x" u32) (field "y" u32)))
    (import "point" (type $pe (eq $point)))
    (import "sumrec" (func $s (param "p" $pe) (result u32)))
    (core func $sc (canon lower (func $s)))
    (core module $MA
      (import "deps" "sumrec" (func $s (param i32 i32) (result i32)))
      (func (export "run") (result i32)
        (call $s (i32.const 7) (i32.const 8))))
    (core instance $deps (export "sumrec" (func $sc)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "run") (result u32)
      (canon lift (core func $ia "run"))))
  (instance $b (instantiate $B))
  (alias export $b "point" (type $bp))
  (instance $a (instantiate $A
    (with "point" (type $bp))
    (with "sumrec" (func $b "sumrec"))))
  (export "run" (func $a "run")))
