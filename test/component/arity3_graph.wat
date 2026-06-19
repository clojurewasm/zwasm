;; D-305 rare-shape fixture: a >2-PARAM arity across the component boundary.
;; B exports `sel(a,b,c: u32) -> u32 = c`. Three flat u32 params flatten to three
;; core i32 words; the existing boundary trampoline is fixed at 2 words
;; (BoundarySig = fn(*Caller,u32,u32)->u32), so `boundaryShapeOk` rejects
;; params.len > 2. All params are PRIMITIVE (no nominal types), so the fixture is
;; the adder graph widened to 3 args. A calls sel(7,8,9), expects c = 9.
(component
  (component $B
    (core module $MB
      (func (export "sel") (param i32 i32 i32) (result i32) local.get 2))
    (core instance $ib (instantiate $MB))
    (func (export "sel") (param "a" u32) (param "b" u32) (param "c" u32) (result u32)
      (canon lift (core func $ib "sel"))))
  (component $A
    (import "sel" (func $s (param "a" u32) (param "b" u32) (param "c" u32) (result u32)))
    (core func $sc (canon lower (func $s)))
    (core module $MA
      (import "deps" "sel" (func $s (param i32 i32 i32) (result i32)))
      (func (export "run") (result i32) (call $s (i32.const 7) (i32.const 8) (i32.const 9))))
    (core instance $deps (export "sel" (func $sc)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "run") (result u32) (canon lift (core func $ia "run"))))
  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "sel" (func $b "sel"))))
  (export "run" (func $a "run")))
