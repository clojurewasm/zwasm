// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! WAT (WebAssembly Text Format) parser — converts .wat to .wasm binary.
//!
//! Conditionally compiled via `-Dwat=false` build option.
//! When disabled, loadFromWat returns error.WatNotEnabled.

const std = @import("std");
const build_options = @import("build_options");

pub const WatError = error{
    WatNotEnabled,
    InvalidWat,
    OutOfMemory,
};

/// Convert WAT text source to wasm binary bytes.
/// Returns allocated slice owned by caller.
pub fn watToWasm(alloc: std.mem.Allocator, wat_source: []const u8) WatError![]u8 {
    if (!build_options.enable_wat) return error.WatNotEnabled;
    _ = alloc;
    _ = wat_source;
    // Stub — will be implemented in 12.2-12.5
    return error.InvalidWat;
}

const testing = std.testing;

test "WAT — build option available" {
    // Verify the build option is accessible at comptime
    if (build_options.enable_wat) {
        // WAT parser enabled — this is the default
        try testing.expect(true);
    } else {
        // WAT parser disabled via -Dwat=false
        try testing.expect(true); // Still valid to compile
    }
}
