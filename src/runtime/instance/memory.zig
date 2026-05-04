//! WASM Spec §4.2.6 "Memory Instance" + memory.copy / .fill /
//! .init helpers.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: reserved slot for
//! the per-instance memory representation. Currently `Runtime.memory:
//! []u8` carries the linear memory directly; this file is the
//! canonical home for a future `MemoryInstance` struct that wraps
//! the slice with limits + page bookkeeping. Bulk-memory and
//! memory64 helpers will move here from `interp/memory_ops.zig`
//! when the §7 item 8 instruction reorg lands.
//!
//! Zone 1 (`src/runtime/`).
