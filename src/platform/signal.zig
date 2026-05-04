//! POSIX signal abstraction — per ADR-0023 §3 reference table,
//! reserved slot for SIGSEGV → trap conversion (Phase 7+).
//!
//! Phase 7 onwards uses guard-page faults to detect linear-memory
//! out-of-bounds accesses without an explicit bounds check on the
//! hot path; this file will host the per-OS signal handler that
//! translates SIGSEGV into a `Trap.OutOfBoundsLoad` /
//! `OutOfBoundsStore`.
//!
//! Currently a placeholder per ADR-0023 §3 P-H (future-state
//! accommodation: reserve directories for subsystems before they
//! land). Implementation begins when guard-page memories are
//! introduced.
//!
//! Zone 0 (`src/platform/`).
