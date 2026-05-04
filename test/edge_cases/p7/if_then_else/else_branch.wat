;; Boundary: if/then/else with cond=0 (else arm). Local-capture
;; pattern (see then_branch.wat for the merge-point rationale).
(module
  (func (export "test") (result i32)
    (local i32)
    (if (i32.const 0)
      (then (i32.const 11) local.set 0)
      (else (i32.const 22) local.set 0))
    local.get 0))
