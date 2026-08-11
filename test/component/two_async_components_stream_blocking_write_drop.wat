;; D-464(1) adversarial ROBUSTNESS (writer-side sibling of blocking_drop): a PARKED
;; (blocked) cross-component stream WRITER whose readable peer is DROPPED must be woken
;; with DROPPED — never deadlock. Exercises the `s.pending.side == .writable` arm of the
;; parked-peer wake (the reader-side sibling is two_async_components_stream_blocking_drop).
;;
;; A mints a `stream<u8>` (r, w), async-calls B's `tick(stream<u8>)` passing the WRITABLE
;; w. B `stream.write(w, …)` with no reader yet → PARKS (BLOCKED), joins w to a waitable
;; set, returns WAIT → B `.waiting`. A then DROPS r (`stream.drop-readable`). The drop must
;; wake B's parked write with DROPPED; B's callback re-writes → DROPPED (low bit) →
;; task.return 99. The test asserts B's task (task 2) result == 99 (not AsyncDeadlock).
(component
  ;; ---- child B: writes BLOCKED, WAITs; on wake re-writes → reports 99 if DROPPED ----
  (component $B
    (type $st (stream u8))
    (core module $MemB (memory (export "mem") 1))
    (core instance $memb (instantiate $MemB))
    (core func $sw (canon stream.write $st (memory $memb "mem")))
    (core func $wsn (canon waitable-set.new))
    (core func $wj (canon waitable.join))
    (core func $b_tr (canon task.return (result u32)))
    (core module $MB
      (import "mem" "mem" (memory 1))
      (import "async" "stream-write" (func $sw (param i32 i32 i32) (result i32)))
      (import "async" "ws-new" (func $wsn (result i32)))
      (import "async" "w-join" (func $wj (param i32 i32)))
      (import "async" "task-return" (func $b_tr (param i32)))
      ;; callback(event_code, p1=waitable=w handle, p2=payload) -> packed result.
      (func (export "callback") (param i32 i32 i32) (result i32)
        (local $code i32)
        (local.set $code (call $sw (local.get 1) (i32.const 0) (i32.const 2))) ;; re-write on wake
        (if (i32.and (local.get $code) (i32.const 1))                          ;; DROPPED low bit?
          (then (call $b_tr (i32.const 99)) (return (i32.const 0))))           ;; saw DROPPED
        (call $b_tr (i32.const 0))
        i32.const 0)
      (func (export "tick") (param i32) (result i32)
        (local $set i32)
        (i32.store8 (i32.const 0) (i32.const 1))              ;; some bytes to write
        (i32.store8 (i32.const 1) (i32.const 2))
        (call $sw (local.get 0) (i32.const 0) (i32.const 2))  ;; write w → PARKS (no reader yet)
        (i32.const -1) (i32.ne) (if (then unreachable))       ;; assert it BLOCKED (0xffffffff)
        (local.set $set (call $wsn))
        (call $wj (local.get 0) (local.get $set))             ;; join the writable end
        (i32.or (i32.shl (local.get $set) (i32.const 4)) (i32.const 2)))) ;; return WAIT(set)
    (core instance $deps
      (export "stream-write" (func $sw))
      (export "ws-new" (func $wsn))
      (export "w-join" (func $wj))
      (export "task-return" (func $b_tr)))
    (core instance $ib (instantiate $MB (with "mem" (instance $memb)) (with "async" (instance $deps))))
    (func (export "tick") async (param "s" $st)
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: mints the stream, async-calls B(w), then DROPS r (no read) ----
  (component $A
    (type $st (stream u8))
    (import "tick" (func $tick async (param "s" $st)))
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $sn (canon stream.new $st))
    (core func $sdr (canon stream.drop-readable $st))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core func $a_tr (canon task.return (result u32)))
    (core module $MA
      (import "async" "stream-new" (func $sn (result i64)))
      (import "async" "stream-drop-readable" (func $sdr (param i32)))
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (import "deps" "task-return" (func $a_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (local $h i64) (local $r i32) (local $w i32)
        (local.set $h (call $sn))                                  ;; mint stream → r | (w<<32)
        (local.set $r (i32.wrap_i64 (local.get $h)))               ;; readable end
        (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))) ;; writable end
        (drop (call $tick (local.get $w)))                         ;; B writes w → BLOCKS → WAITs
        (call $sdr (local.get $r))                                 ;; A DROPS r → must wake B w/ DROPPED
        (call $a_tr (i32.const 0))                                 ;; A's own result (unused) = 0
        i32.const 0))                                              ;; 0 = EXIT
    (core instance $deps
      (export "stream-new" (func $sn))
      (export "stream-drop-readable" (func $sdr))
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
