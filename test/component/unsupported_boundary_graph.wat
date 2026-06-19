;; D-466 regression fixture: a cross-component graph with an UNSUPPORTED boundary
;; shape — B exports wide(x: u64) -> u32. A u64 param is NOT a flat-4 scalar
;; (it flattens to an i64 core word), so boundaryShapeOk rejects it and
;; instantiateGraph returns UnsupportedBoundaryType. (Flat-scalar ARITY is no
;; longer the limit after D-305's generic trampoline — wide scalars / aggregate
;; results remain the typed deferral; this fixture exercises that boundary.)
;; Used by component_tests.zig to assert the FAILED-instantiate cleanup path does
;; not double-free (graph.deinit is the sole owner of appended module/bctx/fctx;
;; the prior local errdefers double-freed). NOT a corpus assert fixture.
(component
  (component $B
    (core module $MB (func (export "wide") (param i64) (result i32) i32.const 0))
    (core instance $ib (instantiate $MB))
    (func (export "wide") (param "x" u64) (result u32)
      (canon lift (core func $ib "wide"))))
  (component $A
    (import "wide" (func $s (param "x" u64) (result u32)))
    (core func $sc (canon lower (func $s)))
    (core module $MA
      (import "deps" "wide" (func $s (param i64) (result i32)))
      (func (export "run") (result i32) (call $s (i64.const 1))))
    (core instance $deps (export "wide" (func $sc)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "run") (result u32) (canon lift (core func $ia "run"))))
  (instance $b (instantiate $B))
  (instance $a (instantiate $A (with "wide" (func $b "wide"))))
  (export "run" (func $a "run")))
