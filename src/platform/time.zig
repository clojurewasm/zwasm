//! Clock + monotonic-time abstraction for WASI 0.1 (Phase 11).
//!
//! Per ADR-0023 §3 reference table: reserved slot for
//! `clock_time_get` / `random_get` / `poll_oneoff` host
//! adapters. The current WASI host at `wasi/clocks.zig` is the
//! interim implementation; Phase 11 promotes the cross-OS
//! adapter here so the WASI subsystem stays platform-neutral.
//!
//! Currently a placeholder per ADR-0023 §3 P-H.
//!
//! Zone 0 (`src/platform/`).
