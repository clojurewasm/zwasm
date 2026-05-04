;; Boundary: if/then/else with cond=1 (then arm). Uses a local
;; to capture the arm's result, sidestepping the operand-stack
;; merge problem at the if's end (both arms must write to the
;; same value-slot — a known emit-pass restructuring deferred
;; to a dedicated cycle). Each arm writes to the same local; at
;; runtime only the taken arm's local.set executes, so the
;; final local.get returns the taken value.
(module
  (func (export "test") (result i32)
    (local i32)
    (if (i32.const 1)
      (then (i32.const 11) local.set 0)
      (else (i32.const 22) local.set 0))
    local.get 0))
