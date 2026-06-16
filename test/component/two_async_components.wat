;; SPIKE (ADR-0195 c-2b): can a 2-component async graph be authored + assembled?
;; Component A async-imports component B's async export `tick`; A's `run`
;; async-calls it. Minimal shape (both EXIT immediately) — proves the COMPOSITION
;; of nested (component) graph + async canon lift/lower parses + validates.
(component
  ;; ---- child B: exports tick: async func() ----
  (component $B
    (core module $MB
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "tick") (result i32) i32.const 0)) ;; 0 = EXIT
    (core instance $ib (instantiate $MB))
    (func (export "tick") async
      (canon lift (core func $ib "tick") async (callback (func $ib "callback"))))
  )

  ;; ---- child A: async-imports tick, exports run: async func() ----
  (component $A
    (import "tick" (func $tick async))
    ;; async lowering needs a memory (subtask storage); the lowered core func
    ;; returns an i32 status (the async call result code).
    (core module $Mem (memory (export "mem") 1))
    (core instance $mem (instantiate $Mem))
    (core func $tick_core (canon lower (func $tick) async (memory $mem "mem")))
    (core module $MA
      (import "deps" "tick" (func $tick (result i32)))
      (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
      (func (export "run") (result i32)
        (drop (call $tick)) ;; start the subtask (async call returns a status)
        i32.const 0))       ;; 0 = EXIT
    (core instance $deps (export "tick" (func $tick_core)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "run") async
      (canon lift (core func $ia "run") async (callback (func $ia "callback"))))
  )

  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "tick" (func $b "tick"))))
  (export "run" (func $a "run"))
)
