;; D-465 adversarial: when the FUTURE reader drops its readable end, the writer's
;; `future.write` must observe DROPPED (not BLOCK / silently complete). This is the
;; valid future-drop scenario (dropping the readable is always allowed; the writer is
;; then released). Exercises the existing `SharedFuture.write` dropped check across a
;; component boundary + the `dropEndGuarded` readable-drop path (sets the dropped flag).
;;
;; A mints a `future<u32>` (r, w), DROPS its own readable r, then async-calls B's
;; `tick(future<u32>)` passing the writable w. B `future.write(w, …)` → the rendezvous
;; is dropped → DROPPED code (`(0 << 4) | 1` == 1). B `task.return`s that raw code; the
;; test asserts B's task (task 2) result == 1.
(component
  ;; ---- child B: tick: async func(future<u32>) — writes, observes DROPPED, reports it ----
  (component $B
    (type $ft (future u32))
    (core module $MemB (memory (export "mem") 1))
    (core instance $memb (instantiate $MemB))
    (core func $fw (canon future.write $ft (memory $memb "mem")))
    (core func $b_tr (canon task.return (result u32)))
    (core module $MB
      (import "mem" "mem" (memory 1))
      (import "async" "future-write" (func $fw (param i32 i32) (result i32)))
      (import "async" "task-return" (func $b_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "tick") (param i32) (result i32)
        (i32.store (i32.const 0) (i32.const 42))            ;; value (unused — reader dropped)
        (call $b_tr (call $fw (local.get 0) (i32.const 0))) ;; write → DROPPED code; task.return it
        i32.const 0))                                       ;; 0 = EXIT
    (core instance $deps (export "future-write" (func $fw)) (export "task-return" (func $b_tr)))
    (core instance $ib (instantiate $MB (with "mem" (instance $memb)) (with "async" (instance $deps))))
    (func (export "tick") async (param "f" $ft)
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: mints the future, DROPS its readable, async-calls B(w) ----
  (component $A
    (type $ft (future u32))
    (import "tick" (func $tick async (param "f" $ft)))
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $fn (canon future.new $ft))
    (core func $fdr (canon future.drop-readable $ft))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core func $a_tr (canon task.return (result u32)))
    (core module $MA
      (import "async" "future-new" (func $fn (result i64)))
      (import "async" "future-drop-readable" (func $fdr (param i32)))
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (import "deps" "task-return" (func $a_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (local $h i64) (local $r i32) (local $w i32)
        (local.set $h (call $fn))                                  ;; mint future → r | (w<<32)
        (local.set $r (i32.wrap_i64 (local.get $h)))               ;; readable end
        (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))) ;; writable end
        (call $fdr (local.get $r))                                 ;; A DROPS its readable end
        (drop (call $tick (local.get $w)))                         ;; B writes w → observes DROPPED
        (call $a_tr (i32.const 0))                                 ;; A returns 0 (no read; r dropped)
        i32.const 0))
    (core instance $deps
      (export "future-new" (func $fn))
      (export "future-drop-readable" (func $fdr))
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
