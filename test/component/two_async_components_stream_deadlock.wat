;; ADR-0195 step (d-c-2), the adversarial (e)-adjacent correctness guard: a
;; cross-component async stream read that BLOCKS forever because the peer NEVER
;; writes → `driveScheduler` MUST trap `error.AsyncDeadlock` (loud), never hang or
;; silently complete with 0. Identical to two_async_components_stream_blocking.wat
;; EXCEPT A omits the `stream.write` — so B's parked read is never resolved, B's
;; task stays `.waiting` with no deliverable pollSet event, and a whole scheduler
;; pass makes no progress → deadlock trap.
(component
  ;; ---- child B: tick: reads BLOCKED, WAITs — and is never woken ----
  (component $B
    (type $st (stream u8))
    (core module $MemB (memory (export "mem") 1))
    (core instance $memb (instantiate $MemB))
    (core func $sr (canon stream.read $st (memory $memb "mem")))
    (core func $wsn (canon waitable-set.new))
    (core func $wj (canon waitable.join))
    (core func $b_tr (canon task.return (result u32)))
    (core module $MB
      (import "mem" "mem" (memory 1))
      (import "async" "stream-read" (func $sr (param i32 i32 i32) (result i32)))
      (import "async" "ws-new" (func $wsn (result i32)))
      (import "async" "w-join" (func $wj (param i32 i32)))
      (import "async" "task-return" (func $b_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32)
        (call $b_tr (i32.const 0)) ;; never reached (no event ever delivered)
        i32.const 0)
      (func (export "tick") (param i32) (result i32)
        (local $set i32)
        (call $sr (local.get 0) (i32.const 0) (i32.const 2)) ;; read r → PARKS
        (i32.const -1) (i32.ne) (if (then unreachable))      ;; assert BLOCKED
        (local.set $set (call $wsn))
        (call $wj (local.get $set) (local.get 0))
        (i32.or (i32.shl (local.get $set) (i32.const 4)) (i32.const 2)))) ;; WAIT(set)
    (core instance $deps
      (export "stream-read" (func $sr))
      (export "ws-new" (func $wsn))
      (export "w-join" (func $wj))
      (export "task-return" (func $b_tr)))
    (core instance $ib (instantiate $MB (with "mem" (instance $memb)) (with "async" (instance $deps))))
    (func (export "tick") async (param "s" $st)
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: mints the stream, async-calls B(r), but NEVER writes ----
  (component $A
    (type $st (stream u8))
    (import "tick" (func $tick async (param "s" $st)))
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $sn (canon stream.new $st))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core func $a_tr (canon task.return (result u32)))
    (core module $MA
      (import "mem" "mem" (memory 1))
      (import "async" "stream-new" (func $sn (result i64)))
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (import "deps" "task-return" (func $a_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (local $h i64) (local $r i32)
        (local.set $h (call $sn))
        (local.set $r (i32.wrap_i64 (local.get $h)))
        (drop (call $tick (local.get $r)))  ;; B blocks on the read — and A never writes
        (call $a_tr (i32.const 0))
        i32.const 0))
    (core instance $deps
      (export "stream-new" (func $sn))
      (export "tick" (func $tick_core))
      (export "task-return" (func $a_tr)))
    (core instance $ia (instantiate $MA (with "mem" (instance $mem)) (with "async" (instance $deps)) (with "deps" (instance $deps))))
    (func (export "run") async (result u32)
      (canon lift (core func $ia "run") async (callback (func $ia "callback"))))
  )

  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "tick" (func $b "tick"))))
  (export "run" (func $a "run"))
)
