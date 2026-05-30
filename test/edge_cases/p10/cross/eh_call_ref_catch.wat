;; Wasm 3.0 cross-feature: exception-handling × function-references.
;; A `try_table (catch $e $h)` body does a `call_ref` to `$thrower`,
;; which `throw`s tag `$e (param i32)`. The exception unwinds OUT of
;; the call_ref'd callee, across the indirect-call boundary, back to
;; the catching handler → the tag's i32 (77) becomes the block result.
;; Exercises the interaction of EH-on-JIT unwinding (ADR-0114) with the
;; funcref-call JIT path (D-207): the unwinder must find the landing pad
;; even though the throw site is inside a function reached via call_ref.
;;
;; Stress axes (test_discipline.md §1): control flow (throw/unwind across
;; a call boundary) + dispatch shape (call_ref → throw). → 77.
;;
;; Provenance: internally derived from 10.P I3 cross-feature close-prep
;; (cyc216); assembled with wasm-tools parse.
(module
  (type $sig (func))
  (tag $e (param i32))
  (func $thrower (type $sig)
    i32.const 77
    throw $e)
  (func (export "test") (result i32)
    (block $h (result i32)
      (try_table (result i32) (catch $e $h)
        (ref.func $thrower)
        (call_ref $sig)
        (i32.const 0))))
  (elem declare func $thrower))
