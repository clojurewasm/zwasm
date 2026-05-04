//! WASM Spec §4.2.8 "Global Instance".
//!
//! Per ADR-0023 §3 reference table + §7 item 6: reserved slot for
//! the per-instance global representation. Currently
//! `Runtime.globals: []*Value` + `globals_storage: []Value`
//! carries the global slots directly with the
//! pointer-per-entry indirection that ADR-0014 §6.K.3 introduced
//! for cross-module global imports. This file is the canonical
//! home for a future `GlobalInstance` struct that pairs each
//! slot with its valtype + mutability.
//!
//! Zone 1 (`src/runtime/`).
