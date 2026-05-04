//! Wasm 2.0 `reference_types` proposal — placeholder per ADR-0023 §7
//! item 8 + §3 reference table.
//!
//! Implementation relocation from `interp/ext_2_0/*` is
//! deferred to ADR-0023 §7 item 18 sweep so the Phase 7 main
//! arc (regalloc / emit / x86_64) is not interrupted by a
//! parser-table re-registration churn.
//!
//! Zone 1 (`src/instruction/`).
