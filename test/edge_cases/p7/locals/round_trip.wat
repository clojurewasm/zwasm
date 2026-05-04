;; Boundary: local.set + local.get round-trip with a non-zero
;; const. Verifies sub-c's locals frame addressing through JIT.
(module
  (func (export "test") (result i32)
    (local i32)
    i32.const 99
    local.set 0
    local.get 0))
