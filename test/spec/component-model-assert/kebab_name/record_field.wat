;; Invalid component: record field label `TyPeS` mixes case within a word —
;; not kebab case (Explainer.md `label` grammar). Official corpus reason:
;; "`TyPeS` is not in kebab case". Encoded via `wasm-tools parse` (no
;; validation); zwasm must REJECT it via the ADR-0176 validator (rule 5).
(component
  (type (record (field "TyPeS" u32)))
)
