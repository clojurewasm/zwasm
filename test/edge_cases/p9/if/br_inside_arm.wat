;; D-096 / d-17: `br N` inside an if-arm targets the if-frame
;; itself. The br carries a value that becomes the if-frame's
;; result. Pre-d-17 `captureOrEmitBlockMergeMov` only captured /
;; emitted MOVs for `.block` targets; if-frame targets fell
;; through to "no merge MOV", so the carried value never reached
;; the post-if consumer.
;;
;; The fixture mirrors `if.wast:param-break` with cond pre-bound
;; to 0 so the else-arm runs deterministically: i32.const 1 + (-2)
;; + i32.add = -1, br 0 carries -1 to the if-frame; function
;; returns -1.
(module
  (func (export "test") (result i32)
    (i32.const 1)
    (if (param i32) (result i32) (i32.const 0)
      (then (i32.const 2) (i32.add) (br 0))
      (else (i32.const -2) (i32.add) (br 0)))))
