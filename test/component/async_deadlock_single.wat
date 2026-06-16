;; WASI-0.3 / CM-async fixture (ADR-0195 Phase II(a) characterization): the
;; single-task DEADLOCK. A guest mints a PLAIN stream (no host peer), reads the
;; readable end → BLOCKED, joins it to a waitable set, and returns WAIT(set).
;; Because nothing will ever write the writable end (single task, no host
;; source), the host loop's `waitOn` polls an empty set → `error.AsyncDeadlock`.
;; This pins the exact behaviour the ADR-0195 multi-task scheduler GENERALISES
;; (all-tasks-blocked + no pending event → trap), so the driver rewrite cannot
;; silently change when the deadlock trap fires.
(component
  (type $st (stream u8))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $sn (canon stream.new $st))
  (core func $rd (canon stream.read $st (memory $libc "mem")))
  (core func $wsn (canon waitable-set.new))
  (core func $wj (canon waitable.join))
  (core module $m
    (import "async" "stream-new" (func $sn (result i64)))
    (import "async" "stream-read" (func $rd (param i32 i32 i32) (result i32)))
    (import "async" "ws-new" (func $wsn (result i32)))
    (import "async" "w-join" (func $wj (param i32 i32)))
    ;; never re-entered: nothing delivers, so the loop deadlocks before any callback.
    (func (export "callback") (param i32 i32 i32) (result i32) unreachable)
    (func (export "run") (result i32)
      (local $h i64) (local $r i32) (local $set i32)
      (local.set $h (call $sn))
      (local.set $r (i32.wrap_i64 (local.get $h)))         ;; readable end (low 32)
      (call $rd (local.get $r) (i32.const 0) (i32.const 1)) ;; read → PARKS (BLOCKED)
      (i32.const -1) (i32.ne) (if (then unreachable))       ;; assert it blocked
      (local.set $set (call $wsn))
      (call $wj (local.get $set) (local.get $r))            ;; join the readable end
      (i32.or (i32.shl (local.get $set) (i32.const 4)) (i32.const 2)))) ;; return WAIT(set)
  (core instance $deps
    (export "stream-new" (func $sn))
    (export "stream-read" (func $rd))
    (export "ws-new" (func $wsn))
    (export "w-join" (func $wj)))
  (core instance $i (instantiate $m (with "async" (instance $deps)) (with "libc" (instance $libc))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
