;; D-465 adversarial: dropping a cross-component FUTURE writable end BEFORE writing
;; its value must TRAP `FutureDropBeforeWrite` (CanonicalABI.md §Future State) — a
;; future MUST deliver exactly one value unless the reader already dropped. The graph
;; future-drop builtin previously skipped this guard (it only refcount-released); the
;; `dropEndGuarded` unification (shared with WASI-P2) now enforces it.
;;
;; A mints a `future<u32>` (r, w), async-calls B's `tick(future<u32>)` passing the
;; writable w. B does NOT write — it calls `future.drop-writable(w)`. The reader (A)
;; has not dropped, so the guard fires → trap. The test asserts `driveAsyncMain` traps
;; (`error.Unreachable`), not BLOCK / silently succeed.
(component
  ;; ---- child B: tick: async func(future<u32>) — drops the writable end before writing ----
  (component $B
    (type $ft (future u32))
    (core module $MemB (memory (export "mem") 1))
    (core instance $memb (instantiate $MemB))
    (core func $fdw (canon future.drop-writable $ft))
    (core module $MB
      (import "async" "future-drop-writable" (func $fdw (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "tick") (param i32) (result i32)
        (call $fdw (local.get 0))    ;; drop writable w BEFORE writing → must trap
        i32.const 0))                ;; (unreachable: the drop traps)
    (core instance $deps (export "future-drop-writable" (func $fdw)))
    (core instance $ib (instantiate $MB (with "async" (instance $deps))))
    (func (export "tick") async (param "f" $ft)
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: mints the future, async-calls B(w); B's drop traps ----
  (component $A
    (type $ft (future u32))
    (import "tick" (func $tick async (param "f" $ft)))
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $fn (canon future.new $ft))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core func $a_tr (canon task.return (result u32)))
    (core module $MA
      (import "async" "future-new" (func $fn (result i64)))
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (import "deps" "task-return" (func $a_tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (local $h i64) (local $w i32)
        (local.set $h (call $fn))                                  ;; mint future → r | (w<<32)
        (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))) ;; writable end
        (drop (call $tick (local.get $w)))                         ;; B drops w before write → trap
        (call $a_tr (i32.const 0))                                 ;; (unreachable)
        i32.const 0))
    (core instance $deps
      (export "future-new" (func $fn))
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
