//! Per-feature DispatchTable registration entry per ADR-0023 §3
//! reference table (`feature/memory64/` subsystem).
//!
//! `register(*DispatchTable)` is the canonical hook — when the
//! build flag `-Denable=memory64` selects this feature in, the
//! central registry calls this function during startup and the
//! function installs the parser / validator / interp / arm64 /
//! x86_64 emit slots for the feature's opcodes.
//!
//! Currently a placeholder per ADR-0023 §3 P-H. Implementation
//! lands per ROADMAP §11 (proposal phasing) when the feature's
//! Phase row opens.
//!
//! Zone 1 (`src/feature/memory64/`).

const dispatch_table = @import("../../ir/dispatch_table.zig");

pub fn register(_: *dispatch_table.DispatchTable) void {
    // Placeholder — feature implementation deferred per ADR-0023.
}
