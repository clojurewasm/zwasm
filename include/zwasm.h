/* zwasm-specific C extensions, subordinate to wasm.h.
 *
 * ADR-0179 #3a-4 (D-314): instance-level sandboxing setters. v1 zwasm
 * exposed CONFIG-level knobs (zwasm_config_set_fuel/...); v2 deliberately
 * mirrors its Zig facade instead — post-instantiate, mid-workload-mutable
 * per-instance budgets. The C API creates interpreter-backed instances
 * (the hardened default engine); `--engine jit` budgets are the CLI
 * surface. All functions are null-tolerant (null instance = no-op).
 *
 * Older extensions (zwasm_instance_get_func, zwasm_store_set_wasi, the
 * zwasm_wasi_config_* family) are exported by the library but not yet
 * declared here; the Phase-16 C-surface audit owns completing this header.
 */
#ifndef ZWASM_H
#define ZWASM_H

#include <stdbool.h>
#include <stdint.h>

#include "wasm.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Fuel (deterministic budget; interp units = instructions) ────────── */

/* Arm (or re-arm) the fuel budget. Exhaustion traps with kind
 * ZWASM_TRAP_OUT_OF_FUEL ("all fuel consumed"). */
WASM_API_EXTERN void zwasm_instance_set_fuel(wasm_instance_t*, uint64_t fuel);

/* Remove the budget (unmetered). */
WASM_API_EXTERN void zwasm_instance_disable_fuel(wasm_instance_t*);

/* Read the remaining fuel into *out; returns false when unmetered. */
WASM_API_EXTERN bool zwasm_instance_fuel_remaining(const wasm_instance_t*, uint64_t* out);

/* ── Memory cap (host ceiling below the declared/spec max) ───────────── */

/* memory.grow past `max_pages` (pages of memory 0's page size, 64 KiB by
 * default) returns the spec grow-failure (-1) — not a trap. */
WASM_API_EXTERN void zwasm_instance_set_memory_pages_limit(wasm_instance_t*, uint64_t max_pages);
WASM_API_EXTERN void zwasm_instance_clear_memory_pages_limit(wasm_instance_t*);

/* ── Cooperative interruption (cancel / host-driven timeout) ─────────── */

/* Callable from any thread; the running guest traps with kind
 * ZWASM_TRAP_INTERRUPTED at its next poll (function entry / loop
 * back-edge). Idempotent; clear before re-invoking. */
WASM_API_EXTERN void zwasm_instance_interrupt(wasm_instance_t*);
WASM_API_EXTERN void zwasm_instance_clear_interrupt(wasm_instance_t*);

/* ── Trap kind introspection ─────────────────────────────────────────── */

/* Machine-readable trap kind beside wasm.h's message-only surface; -1 on
 * NULL. Stable values for the sandboxing kinds: */
#define ZWASM_TRAP_INTERRUPTED 16
#define ZWASM_TRAP_OUT_OF_FUEL 17
WASM_API_EXTERN int32_t zwasm_trap_kind(const wasm_trap_t*);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* ZWASM_H */
