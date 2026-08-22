;; `br_on_non_null` narrows the popped `(ref null ht)` to `(ref ht)` before
;; checking it against the label (Wasm 3.0 §3.3.10.9). With a `nullref`
;; operand the narrowed form is `(ref none)`, which must satisfy a
;; `(ref $s)` label — the same #224 bottom edge, reached through a THIRD
;; code path: that site called the CONTEXT-FREE `valTypeIsSubtypeFree`, which
;; cannot resolve `$s`'s typedef kind and therefore answered `false`. Fixing
;; only the two context-aware subtype functions leaves this one rejecting.
;; wasm-tools and V8 accept.
;;
;; Stress axes (test_discipline.md §1): validator boundary (bottom heap type
;; -> concrete typedef) x control-flow (br_on_non_null narrowing) x label
;; arity (single-result AND multi-result label types, which are separate
;; arms of the branch check).
;;
;; Provenance: hand-written; found by sweeping the callers of the
;; context-free subtype helper after the #224 reduction (test_discipline §2).
(module
  (type $s (struct (field i32)))

  ;; Single-result label: narrowed `(ref none)` vs `(ref $s)`. The operand is
  ;; always null, so this always falls through — the branch edge is what must
  ;; VALIDATE.
  (func $bottom_single (result i32)
    (block $l (result (ref $s))
      ref.null none
      br_on_non_null $l
      i32.const 100
      return)
    struct.get $s 0)

  ;; Multi-result label: the branch check walks a different arm.
  (func $bottom_multi (result i32)
    (block $l (result i32 (ref $s))
      i32.const 5
      ref.null none
      br_on_non_null $l
      i32.const 10
      return)
    struct.get $s 0
    i32.add)

  ;; Control: a genuinely non-null operand does take the branch.
  (func $taken (param $r (ref null $s)) (result i32)
    (block $l (result (ref $s))
      local.get $r
      br_on_non_null $l
      i32.const 1000
      return)
    struct.get $s 0)

  (func (export "test") (result i32)
    call $bottom_single      ;; 100
    call $bottom_multi       ;; 10
    i32.add                  ;; 110
    i32.const 11
    struct.new $s
    call $taken              ;; 11
    i32.add))                ;; 121
