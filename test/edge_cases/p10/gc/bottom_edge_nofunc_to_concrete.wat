;; Wasm 3.0 GC `Heaptype_sub/nofunc`: `NOFUNC <: ht` holds for every
;; `ht <: FUNC`, so `nullfuncref` reaches a concrete FUNC typedef — the
;; func-hierarchy half of the #224 bottom edge, which the validator's
;; hard-coded abstract->concrete `false` rejected alongside the struct/array
;; half. The two halves are NOT interchangeable: `none` does NOT reach a func
;; typedef and `nofunc` does NOT reach a struct/array one (`NONE` needs
;; `ht <: ANY`, `NOFUNC` needs `ht <: FUNC`), so "bottom implies subtype"
;; would be wrong. Those cross-hierarchy rejections are asserted in
;; `validator_tests.zig` (an invalid module has no fixture form here).
;;
;; Stress axes (test_discipline.md §1): validator boundary (bottom heap type
;; -> concrete typedef) x hierarchy (func, disjoint from the any-rooted one)
;; x site (return / local.set / global init-expr / table.fill element).
;;
;; Provenance: hand-written sibling of `bottom_edge_none_to_concrete`
;; (test_discipline §2 same-shape sweep); wasm-tools parse.
(module
  (type $f0 (func (result i32)))
  (table $t 2 (ref null $f0))

  (global $g (ref null $f0) (ref.null nofunc))

  (func $ret_nullfunc (result (ref null $f0))
    ref.null nofunc
    return)

  (func (export "test") (result i32)
    (local $l (ref null $f0))
    call $ret_nullfunc
    ref.is_null              ;; 1
    global.get $g
    ref.is_null              ;; 1
    i32.add                  ;; 2
    ref.null nofunc
    local.set $l             ;; local.set: nullfuncref -> (ref null $f0)
    local.get $l
    ref.is_null              ;; 1
    i32.add                  ;; 3
    i32.const 0
    ref.null nofunc          ;; table.fill element: nullfuncref -> (ref null $f0)
    i32.const 2
    table.fill $t
    i32.const 1
    table.get $t
    ref.is_null              ;; 1
    i32.add))                ;; 4
