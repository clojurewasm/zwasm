;; ADR-0195 step (d-c-2): the BLOCKING guest↔guest async STREAM rendezvous across
;; a component graph — the read-first (parked) path d-c-1 deferred. Component A's
;; `run: async func() -> u32` mints a `stream<u8>` (readable r + writable w),
;; async-calls B's `tick: async func(stream<u8>)` passing the READABLE handle r.
;;
;; B runs DURING the async call (synchronous enqueue): it `stream.read(r, &buf, 2)`
;; with NO bytes yet available → the read PARKS (returns BLOCKED, 0xffffffff). B then
;; `waitable-set.new` + joins r and returns WAIT(set) → B's task becomes `.waiting`.
;; Control returns to A. A `stream.write(w, &{20,22}, 2)` — the rendezvous resolves
;; B's parked read: the 2 bytes are copied into B's memory and B's read-end gets a
;; STREAM_READ pending_event. A task.returns 0 and EXITs.
;;
;; `driveScheduler` then polls B's `.waiting` task → `GraphAsyncCtx.pollSet` fetches
;; B's set, finds the read-end pending_event, returns STREAM_READ → B's `callback`
;; re-enters, reads the delivered bytes (20+22 == 42) and `task.return(42)`, EXIT.
;; The test asserts B's OWN task result == 42, proving the value crossed A→B through
;; the BLOCKING (park-then-deliver) path + the pollSet/waitable-set delivery — NOT
;; the synchronous d-c-1 path (B genuinely went `.waiting` and was re-entered).
(component
  ;; ---- child B: tick: async func(stream<u8>) — reads BLOCKED, WAITs, then sums {20,22} ----
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
      ;; callback(event_code, p1=waitable, p2=payload) -> packed result.
      (func (export "callback") (param i32 i32 i32) (result i32)
        (if (i32.ne (local.get 0) (i32.const 2)) (then unreachable)) ;; STREAM_READ=2
        (call $b_tr (i32.add                                          ;; task.return(20+22 == 42)
          (i32.load8_u (i32.const 0))
          (i32.load8_u (i32.const 1))))
        i32.const 0)                                                  ;; 0 = EXIT
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

  ;; ---- child A: mints the stream, async-calls B(r), writes {20,22} into w, EXITs ----
  (component $A
    (type $st (stream u8))
    (import "tick" (func $tick async (param "s" $st)))
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $sn (canon stream.new $st))
    (core func $sw (canon stream.write $st (memory $mem "mem")))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core func $a_tr (canon task.return (result u32)))
    (core module $MA
      (import "mem" "mem" (memory 1))
      (import "async" "stream-new" (func $sn (result i64)))
      (import "async" "stream-write" (func $sw (param i32 i32 i32) (result i32)))
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (import "deps" "task-return" (func $a_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (local $h i64) (local $r i32) (local $w i32)
        (local.set $h (call $sn))                                  ;; mint stream → ri|wi<<32
        (local.set $r (i32.wrap_i64 (local.get $h)))               ;; readable end
        (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))) ;; writable end
        (drop (call $tick (local.get $r)))                         ;; B runs now: reads r → BLOCKS → WAITs
        (i32.store8 (i32.const 0) (i32.const 20))                  ;; bytes to send
        (i32.store8 (i32.const 1) (i32.const 22))
        (drop (call $sw (local.get $w) (i32.const 0) (i32.const 2))) ;; write → resolves B's parked read
        (call $a_tr (i32.const 0))                                 ;; A's own result (unused) = 0
        i32.const 0))                                              ;; 0 = EXIT
    (core instance $deps
      (export "stream-new" (func $sn))
      (export "stream-write" (func $sw))
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
