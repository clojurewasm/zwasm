;; D-093 (d-10) regression: `(if (param i32) (result i32))` validator
;; opElse re-push + emit param_top_vregs capture/restore + liveness
;; if-frame tracking. The if takes param=1 and cond=1 → then-arm
;; consumes the param as 1 + 2 = 3.
;;
;; Provenance: if.wast `param` export (Wasm 2.0 spec corpus).
;; Pre-d-10 the validator's `opElse` did not re-push start (param)
;; types, surfacing as StackUnderflow during validate. Even with
;; the validator fix, emit's `emitElse` left the then-arm's result
;; vreg on top of the operand stack so the else-arm body operated
;; on the wrong shape; the d-10 emit capture+restore + the
;; emitEndIntra param-aware merge path produces a correct merge.
;;
;; Expected: 3.
(module
  (func (export "test") (result i32)
    (i32.const 1)
    (if (param i32) (result i32) (i32.const 1)
      (then (i32.const 2) (i32.add))
      (else (i32.const -2) (i32.add)))))
