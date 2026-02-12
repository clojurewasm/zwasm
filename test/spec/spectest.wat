;; spectest host module for Wasm spec tests.
;; Provides the standard "spectest" imports expected by the test suite.
(module
  ;; Functions (all no-ops)
  (func (export "print"))
  (func (export "print_i32") (param i32))
  (func (export "print_i64") (param i64))
  (func (export "print_f32") (param f32))
  (func (export "print_f64") (param f64))
  (func (export "print_f64_f64") (param f64 f64))
  (func (export "print_i32_f32") (param i32 f32))

  ;; Memory: 1 page min, 2 pages max
  (memory (export "memory") 1 2)

  ;; Table: 10 elements min, 20 max, funcref
  (table (export "table") 10 20 funcref)

  ;; Globals
  (global (export "global_i32") i32 (i32.const 666))
  (global (export "global_i64") i64 (i64.const 666))
  (global (export "global_f32") f32 (f32.const 666.6))
  (global (export "global_f64") f64 (f64.const 666.6))
)
