;; Wasm 3.0 GC `Heaptype_sub/none`: `NONE <: ht` holds for EVERY `ht` with
;; `ht <: ANY`, and a concrete `$t`'s head is the kind of its typedef
;; (`Heaptype_sub/{struct,array}`) — so `nullref` and `(ref none)` flow into
;; `(ref null $struct)`, `(ref $struct)` and the array forms alike. The
;; validator's abstract->concrete arm was hard-coded `false`, so every one of
;; these was rejected with `type mismatch: expected (ref $type), found
;; nullref`. Issue #224: MoonBit's wasm-gc backend emits exactly this shape
;; for `Double` formatting (`ref.null none; return` against a
;; `(ref null $t)` result); V8 and wasmtime both accept it.
;;
;; Stress axes (test_discipline.md §1): validator boundary (bottom heap type
;; -> concrete typedef) x nullability (both `(ref null $t)` and `(ref $t)`
;; targets) x head kind (struct AND array) x site (return / local.set / call
;; argument / struct.new field / global init-expr).
;;
;; Provenance: hand-written reduction of the #224 MoonBit repro (its func #8
;; is `(result (ref null $t))` with `ref.null none; return`); wasm-tools parse.
(module
  (type $s (struct (field i32)))
  (type $a (array (mut i32)))
  (type $box (struct (field (ref null $s))))

  ;; global init-expr: the module-level subtype path (not the type stack).
  (global $g (ref null $s) (ref.null none))

  ;; `return` against a nullable concrete result — the #224 shape verbatim.
  (func $ret_struct (result (ref null $s))
    ref.null none
    return)

  ;; Same edge, array head of the same (any-rooted) hierarchy.
  (func $ret_array (result (ref null $a))
    ref.null none
    return)

  ;; NON-NULL on both sides: `(ref none)` <: `(ref $s)`. `(ref none)` is
  ;; uninhabited, so the `then` arm cannot run — the assertion is that it
  ;; VALIDATES. Nullability is a separate gate and still rejects
  ;; `(ref null none)` here, which is why this arm needs `ref.as_non_null`.
  (func $nonnull_bottom (param $go i32) (result (ref $s))
    local.get $go
    if (result (ref $s))
      ref.null none
      ref.as_non_null
    else
      i32.const 7
      struct.new $s
    end)

  (func $takes (param (ref null $s)) (result i32)
    local.get 0
    ref.is_null)

  (func (export "test") (result i32)
    (local $l (ref null $a))
    call $ret_struct
    ref.is_null              ;; 1
    call $ret_array
    ref.is_null              ;; 1
    i32.add                  ;; 2
    ref.null none
    local.set $l             ;; local.set: nullref -> (ref null $a)
    local.get $l
    ref.is_null              ;; 1
    i32.add                  ;; 3
    ref.null none
    call $takes              ;; call arg: nullref -> (ref null $s)
    i32.add                  ;; 4
    ref.null none
    struct.new $box          ;; field init: nullref -> (ref null $s)
    struct.get $box 0
    ref.is_null              ;; 1
    i32.add                  ;; 5
    global.get $g
    ref.is_null              ;; 1
    i32.add                  ;; 6
    i32.const 0
    call $nonnull_bottom     ;; else arm at run time; then arm proves validation
    struct.get $s 0          ;; 7
    i32.add))                ;; 13
