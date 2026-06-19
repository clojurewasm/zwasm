;; D-305: a 5-PARAM arity cross-component boundary — the forcing function for
;; the generic `defineFuncRaw` arity-collapse. B exports sel5(a,b,c,d,e: u32) ->
;; u32 = e. Five flat u32 params flatten to five core i32 words; the per-arity
;; trampolines stopped at four (BoundarySig4), so boundaryShapeOk rejected
;; params.len == 5 with UnsupportedBoundaryType. The Value-slice generic path
;; removes the per-arity ceiling. All primitive (no nominal types).
;; A calls sel5(7,8,9,10,11), expects e = 11.
(component
  (component $B
    (core module $MB
      (func (export "sel5") (param i32 i32 i32 i32 i32) (result i32) local.get 4))
    (core instance $ib (instantiate $MB))
    (func (export "sel5") (param "a" u32)(param "b" u32)(param "c" u32)(param "d" u32)(param "e" u32) (result u32)
      (canon lift (core func $ib "sel5"))))
  (component $A
    (import "sel5" (func $s (param "a" u32)(param "b" u32)(param "c" u32)(param "d" u32)(param "e" u32) (result u32)))
    (core func $sc (canon lower (func $s)))
    (core module $MA
      (import "deps" "sel5" (func $s (param i32 i32 i32 i32 i32) (result i32)))
      (func (export "run") (result i32)
        (call $s (i32.const 7)(i32.const 8)(i32.const 9)(i32.const 10)(i32.const 11))))
    (core instance $deps (export "sel5" (func $sc)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "run") (result u32) (canon lift (core func $ia "run"))))
  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "sel5" (func $b "sel5"))))
  (export "run" (func $a "run")))
