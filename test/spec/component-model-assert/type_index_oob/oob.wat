;; Invalid component: a func type whose param references type index 9, but the
;; type-index space has only one entry (index 0 = this func). The official
;; WebAssembly/component-model corpus calls this "type index out of bounds".
;; Encoded with `wasm-tools parse` (no validation); zwasm must REJECT it via
;; the ADR-0176 component validator (Error.InvalidTypeIndex), not accept it.
(component
  (type $f (func (param "x" 9)))
)
