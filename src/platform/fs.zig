//! Filesystem abstraction for WASI capabilities (Phase 11).
//!
//! Per ADR-0023 §3 reference table: reserved slot for the
//! capability-checked filesystem layer that backs WASI 0.1
//! `path_open` / `fd_read` / `fd_write` / `fd_close` /
//! `fd_seek` / `fd_tell` / `fd_fdstat_*`. The current WASI host
//! at `wasi/host.zig` does the per-call work directly via
//! `std.Io.File`; Phase 11 carves the capability check out so the
//! sandboxing surface is testable in isolation.
//!
//! Currently a placeholder per ADR-0023 §3 P-H.
//!
//! Zone 0 (`src/platform/`).
