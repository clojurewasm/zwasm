//! WASM Spec §4.2.10 "Data Segment State" — memory.init /
//! data.drop targets.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: reserved slot for
//! the per-instance data-segment representation. Currently
//! `Runtime.datas: []const []const u8` + `data_dropped: []bool`
//! carry the data-segment runtime state directly. This file is
//! the canonical home for a future `DataInstance` struct.
//!
//! Zone 1 (`src/runtime/`).
