// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! ARM64 NEON SIMD codegen for JIT compiler.
//! Emits NEON instructions for wasm SIMD (v128) opcodes.
//! Design: D130 in .dev/decisions.md.

const std = @import("std");

/// Placeholder: emit ARM64 NEON instruction for a SIMD opcode.
/// Returns false if the opcode is not yet implemented (caller should bail).
pub fn emit(_sub: u32) bool {
    _ = _sub;
    return false; // No opcodes implemented yet
}
