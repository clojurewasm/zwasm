;; Boundary: block wrapping a constant push, no internal branch.
;; Tests sub-7.5c-iii's structural-marker liveness extension —
;; block/end pass through transparently while the inner
;; i32.const flows to the function result.
;;
;; Expected: the block produces 7, function returns 7.
(module
  (func (export "test") (result i32)
    (block (result i32)
      i32.const 7)))
