;; spectest host module for Wasm spec tests.
;;
;; Canonical source: WebAssembly/spec/interpreter/host/spectest.ml
;;   pinned reference: commit f5a260a20 (SIMD proposal merge, 2026-pre)
;;   read-only clone at ~/Documents/OSS/WebAssembly/spec/
;;
;; Cross-checked against:
;;   - wazero internal/integration_test/spectest/testdata/spectest.wat
;;   - zwasm v1 test/spec/spectest.wat
;;
;; Re-derived per .claude/rules/no_copy_from_v1.md — byte-for-byte
;; convergence with v1 / wazero is expected because the OCaml
;; canonical spec is the single source of truth.
;;
;; Upstream-tracking: if spec/interpreter/host/spectest.ml gains
;; (or modifies) an entry, mirror the change here and bump the
;; commit-sha reference above.

(module $spectest
  ;; Globals — immutable, values per spectest.ml lines 13-17.
  (global (export "global_i32") i32 (i32.const 666))
  (global (export "global_i64") i64 (i64.const 666))
  (global (export "global_f32") f32 (f32.const 666.6))
  (global (export "global_f64") f64 (f64.const 666.6))

  ;; Table — funcref, 10..20 (spectest.ml line 21-23).
  (table (export "table") 10 20 funcref)

  ;; Memory — 1..2 pages (spectest.ml line 24).
  (memory (export "memory") 1 2)

  ;; Functions — drop-only no-ops (spectest.ml prints to stdout
  ;; in OCaml; .wat impl is allowed to drop per host-effect
  ;; latitude in the spec). Matches wazero + v1 behaviour.
  (func (export "print"))
  (func (export "print_i32") (param i32))
  (func (export "print_i64") (param i64))
  (func (export "print_f32") (param f32))
  (func (export "print_f64") (param f64))
  (func (export "print_i32_f32") (param i32 f32))
  (func (export "print_f64_f64") (param f64 f64))
)
