;; Boundary: function calling another function (no args, i32
;; result). Tests sub-7.5c-ii's liveness extension for `call`,
;; the linker's BL fixup patching, and ADR-0017's runtime ABI
;; in a multi-function context.
;;
;; Provenance: sub-7.5c-ii — first multi-function fixture
;; running end-to-end through the JIT pipeline.
(module
  (func $callee (result i32)
    i32.const 42)
  (func (export "test") (result i32)
    call $callee))
