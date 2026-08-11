//! WASI Preview-2 surface — ADR-0207 M2 facade.
//!
//! During the three-way split (D-444) every public symbol re-exports from
//! the substrate file `component_wasi_ctx.zig`; the P2 trampoline clusters
//! and the classifier/orchestration layer move IN here per-cluster at M3,
//! and the fs3/sock3/http3 layer moves to `component_wasi_p3_host.zig`.
//! External importers (component.zig / component_tests.zig /
//! component_wasi_p3.zig) are untouched by the split.

const ctx_mod = @import("component_wasi_ctx.zig");

// Parked-work / role value types.
pub const PendingRead = ctx_mod.PendingRead;
pub const PendingWrite = ctx_mod.PendingWrite;
pub const ParkedSockRead = ctx_mod.ParkedSockRead;
pub const TcpTxRole = ctx_mod.TcpTxRole;
pub const ParkedUdpReceive = ctx_mod.ParkedUdpReceive;
pub const HostBodyBytes = ctx_mod.HostBodyBytes;
pub const PendingClientSend = ctx_mod.PendingClientSend;

// Core context + error set.
pub const WasiP2Ctx = ctx_mod.WasiP2Ctx;
pub const WasiP2Error = ctx_mod.WasiP2Error;

// Async / resource builtin contexts (canon-builtin binding layer).
pub const AsyncBuiltinCtx = ctx_mod.AsyncBuiltinCtx;
pub const ResourceBuiltinCtx = ctx_mod.ResourceBuiltinCtx;
pub const GuestDtor = ctx_mod.GuestDtor;
pub const ContextBuiltinCtx = ctx_mod.ContextBuiltinCtx;
pub const DropResourceError = ctx_mod.DropResourceError;

// P2 trampolines consumed by name from component_tests.zig.
pub const p2GetStdout = ctx_mod.p2GetStdout;
pub const p2OutStreamWrite = ctx_mod.p2OutStreamWrite;
pub const p2OutStreamDrop = ctx_mod.p2OutStreamDrop;
pub const p2DescriptorWrite = ctx_mod.p2DescriptorWrite;
pub const p2DescriptorDrop = ctx_mod.p2DescriptorDrop;
pub const p2DescriptorOpenAt = ctx_mod.p2DescriptorOpenAt;
pub const p2GetDirectories = ctx_mod.p2GetDirectories;

// Component build / run orchestration.
pub const BuiltComponent = ctx_mod.BuiltComponent;
pub const buildWasiP2Component = ctx_mod.buildWasiP2Component;
pub const runWasiP2Main = ctx_mod.runWasiP2Main;
pub const runWasiP2MainBuilt = ctx_mod.runWasiP2MainBuilt;
pub const runWasiMain = ctx_mod.runWasiMain;

// P3-side pubs (consumed by component_wasi_p3.zig; move to the P3 host
// file at M3, re-export stays per ADR-0207 I1).
pub const http3DropTransferredEnd = ctx_mod.http3DropTransferredEnd;
pub const pollPendingClientSends = ctx_mod.pollPendingClientSends;
pub const http3RegisterCaptureSink = ctx_mod.http3RegisterCaptureSink;
