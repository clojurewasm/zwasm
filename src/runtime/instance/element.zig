//! WASM Spec §4.2.9 "Element Segment State" — table.init /
//! elem.drop targets.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: reserved slot for
//! the per-instance element-segment representation. Currently
//! `Runtime.elems: []const []const Value` + `elem_dropped: []bool`
//! carry the element-segment runtime state directly. This file is
//! the canonical home for a future `ElementInstance` struct.
//!
//! Zone 1 (`src/runtime/`).
