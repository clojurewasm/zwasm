;; D-464(1) adversarial ROBUSTNESS: a PARKED (blocked) cross-component stream reader
;; whose writable peer is DROPPED must be woken with DROPPED — never deadlock/hang.
;;
;; Like the d-c-2 blocking fixture: A mints a `stream<u8>` (r, w), async-calls B's
;; `tick(stream<u8>)` passing the READABLE r. B `stream.read(r)` → PARKS (BLOCKED),
;; joins r to a waitable-set, returns WAIT(set) → B `.waiting`. But A then DROPS w
;; (`stream.drop-writable`) instead of writing. The drop must wake B's parked read
;; with DROPPED; B's callback re-reads → DROPPED (low bit set) → task.return 99. The
;; test asserts B's task (task 2) result == 99. If the drop does NOT notify the parked
;; reader, `driveScheduler` makes no progress → AsyncDeadlock (the bug this pins).
(component
  ;; ---- child B: reads BLOCKED, WAITs; on wake re-reads → reports 99 if DROPPED ----
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
      ;; callback(event_code, p1=waitable=r handle, p2=payload) -> packed result.
      (func (export "callback") (param i32 i32 i32) (result i32)
        (local $code i32)
        (local.set $code (call $sr (local.get 1) (i32.const 0) (i32.const 2))) ;; re-read on wake
        (if (i32.and (local.get $code) (i32.const 1))                          ;; DROPPED low bit?
          (then (call $b_tr (i32.const 99)) (return (i32.const 0))))           ;; saw DROPPED
        (call $b_tr (i32.add (i32.load8_u (i32.const 0)) (i32.load8_u (i32.const 1))))
        i32.const 0)
      (func (export "tick") (param i32) (result i32)
        (local $set i32)
        (call $sr (local.get 0) (i32.const 0) (i32.const 2)) ;; read r → PARKS (no writer yet)
        (i32.const -1) (i32.ne) (if (then unreachable))      ;; assert it BLOCKED (0xffffffff)
        (local.set $set (call $wsn))
        (call $wj (local.get $set) (local.get 0))            ;; join the readable end
        (i32.or (i32.shl (local.get $set) (i32.const 4)) (i32.const 2)))) ;; return WAIT(set)
    (core instance $deps
      (export "stream-read" (func $sr))
      (export "ws-new" (func $wsn))
      (export "w-join" (func $wj))
      (export "task-return" (func $b_tr)))
    (core instance $ib (instantiate $MB (with "mem" (instance $memb)) (with "async" (instance $deps))))
    (func (export "tick") async (param "s" $st)
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: mints the stream, async-calls B(r), then DROPS w (no write) ----
  (component $A
    (type $st (stream u8))
    (import "tick" (func $tick async (param "s" $st)))
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $sn (canon stream.new $st))
    (core func $sdw (canon stream.drop-writable $st))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core func $a_tr (canon task.return (result u32)))
    (core module $MA
      (import "async" "stream-new" (func $sn (result i64)))
      (import "async" "stream-drop-writable" (func $sdw (param i32)))
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (import "deps" "task-return" (func $a_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (local $h i64) (local $r i32) (local $w i32)
        (local.set $h (call $sn))                                  ;; mint stream → r | (w<<32)
        (local.set $r (i32.wrap_i64 (local.get $h)))               ;; readable end
        (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))) ;; writable end
        (drop (call $tick (local.get $r)))                         ;; B reads r → BLOCKS → WAITs
        (call $sdw (local.get $w))                                 ;; A DROPS w → must wake B w/ DROPPED
        (call $a_tr (i32.const 0))                                 ;; A's own result (unused) = 0
        i32.const 0))                                              ;; 0 = EXIT
    (core instance $deps
      (export "stream-new" (func $sn))
      (export "stream-drop-writable" (func $sdw))
      (export "tick" (func $tick_core))
      (export "task-return" (func $a_tr)))
    (core instance $ia (instantiate $MA (with "async" (instance $deps)) (with "deps" (instance $deps))))
    (func (export "run") async (result u32)
      (canon lift (core func $ia "run") async (callback (func $ia "callback"))))
  )

  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "tick" (func $b "tick"))))
  (export "run" (func $a "run"))
)
