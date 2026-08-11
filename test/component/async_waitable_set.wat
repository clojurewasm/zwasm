;; WASI-0.3 / CM-async fixture (D-335 unit E2b, ADR-0190): the waitable-set host
;; builtins. A guest mints a stream + a waitable set, joins the stream's readable
;; end to the set, then EXITs. Exercises waitable-set.new + waitable.join (the
;; guest-facing set-construction builtins the stackless WAIT path uses to name a
;; set of waitables). The host asserts the set holds the joined member.
(component
  (type $st (stream u8))
  (core func $sn (canon stream.new $st))
  (core func $wsn (canon waitable-set.new))
  (core func $wj (canon waitable.join))
  (core module $m
    (import "async" "stream-new" (func $sn (result i64)))
    (import "async" "ws-new" (func $wsn (result i32)))
    (import "async" "w-join" (func $wj (param i32 i32)))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $h i64) (local $set i32)
      (local.set $h (call $sn))
      (local.set $set (call $wsn)) ;; mint an empty waitable set
      ;; join the readable end (ri = low 32) to the set
      (call $wj (i32.wrap_i64 (local.get $h)) (local.get $set))
      i32.const 0)) ;; 0 = EXIT
  (core instance $deps
    (export "stream-new" (func $sn))
    (export "ws-new" (func $wsn))
    (export "w-join" (func $wj)))
  (core instance $i (instantiate $m (with "async" (instance $deps))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
