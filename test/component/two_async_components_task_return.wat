;; ADR-0195 step (d-a): the smallest guest↔guest async DATA transfer. Component A
;; async-imports component B's async export `tick: async func() -> u32`; A's `run`
;; async-calls it. B's core `tick` calls `task.return(42)` to deliver its result,
;; then EXITs. The graph-level task.return wiring captures 42 into B's subtask's
;; per-task result slot (TaskDescriptor.result). Mirrors two_async_components.wat
;; (the void c-2b shape) + the single-component task.return spelling in
;; async_task_return.wat (B's core imports `task.return` via an inline synthetic
;; core instance).
(component
  ;; ---- child B: exports tick: async func() -> u32 (delivers 42) ----
  (component $B
    (core func $tr (canon task.return (result u32)))
    (core module $MB
      (import "async" "task-return" (func $tr (param i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "tick") (result i32)
        (call $tr (i32.const 42)) ;; deliver result 42
        i32.const 0))             ;; 0 = EXIT
    (core instance $deps (export "task-return" (func $tr)))
    (core instance $ib (instantiate $MB (with "async" (instance $deps))))
    (func (export "tick") async (result u32)
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: async-imports tick, exports run: async func() ----
  (component $A
    (import "tick" (func $tick async (result u32)))
    ;; async lowering needs a memory (subtask storage); the lowered core func
    ;; of a result-bearing async import is `(param retptr i32) -> (result i32)`:
    ;; the retptr names where the subtask's u32 result lands; the result is the
    ;; async-call status code.
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core module $MA
      (import "deps" "tick" (func $tick (param i32) (result i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (drop (call $tick (i32.const 0))) ;; start the subtask (retptr=0; status dropped)
        i32.const 0))                     ;; 0 = EXIT
    (core instance $deps (export "tick" (func $tick_core)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "run") async
      (canon lift (core func $ia "run") async (callback (func $ia "callback"))))
  )

  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "tick" (func $b "tick"))))
  (export "run" (func $a "run"))
)
