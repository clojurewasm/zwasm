;; Invalid component: a func import ascribed type index 99, but the type-index
;; space is empty. Official corpus: "type index out of bounds". Encoded via
;; `wasm-tools parse` (no validation); zwasm must REJECT it via the ADR-0176
;; validator (rule 4: ExternDesc type-index bounds).
(component
  (import "a-func" (func (type 99)))
)
