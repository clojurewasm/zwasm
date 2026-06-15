;; WASI-0.3 / CM-async fixture (D-335 / D-445): a guest calls waitable.join with
;; a set handle it never minted (999) → the host set table returns InvalidHandle.
;; A guest-supplied bad set handle is a guest fault, so the call traps rather
;; than aborting the host (the waitable.join trampoline's mapAsyncFault narrowing).
(component
  (core func $wj (canon waitable.join))
  (core module $m
    (import "async" "w-join" (func $wj (param i32 i32)))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      ;; join into a never-minted set (handle 999, waitable 1) → InvalidHandle → traps
      (call $wj (i32.const 999) (i32.const 1))
      i32.const 0)) ;; a clean EXIT here would mean the bad set handle did NOT trap
  (core instance $deps
    (export "w-join" (func $wj)))
  (core instance $i (instantiate $m (with "async" (instance $deps))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
