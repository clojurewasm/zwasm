;; WASI-0.3 / CM-async minimal fixture (D-335 unit D-ηB, ADR-0188): an
;; async-lifted export whose core task entry returns EXIT (0) immediately, so
;; the stackless callback loop terminates without delivering any event (no
;; task.return needed — the export is result-less). Exercises the P3 runner's
;; instantiate -> invoke task-entry -> driveCallbackLoop -> EXIT path.
;; Async-lift WAT spelling verified vs wasmtime
;; tests/misc_testsuite/component-model/async/lift.wast.
(component
  (core module $m
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32) i32.const 0)) ;; 0 = EXIT
  (core instance $i (instantiate $m))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
