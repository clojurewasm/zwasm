;; D-097 d-18 minimal: `select` with TWO force-spilled i32
;; operands and a register cond. No if-frame; pure spans_call
;; pattern. cond=3 → val1=2. Expected 2.
(module
  (func $dummy)
  (func (export "test") (result i32)
    (i32.const 2)
    (call $dummy)
    (i32.const 0)
    (call $dummy)
    (i32.const 3)
    (select)))
