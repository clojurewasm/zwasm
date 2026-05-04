//! Wasm 1.0 §5.4 `numeric_int` instruction category — placeholder per
//! ADR-0023 §7 item 8 + §3 reference table.
//!
//! Implementation moves here from the legacy `interp/{mvp,
//! mvp_int, mvp_float, mvp_conversions, memory_ops}.zig`
//! during ADR-0023 §7 item 18 sweep. Until then, those files
//! continue to host the live handlers and the central
//! DispatchTable still routes through them.
//!
//! Zone 1 (`src/instruction/`).
