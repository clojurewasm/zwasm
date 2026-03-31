/*
 * zwasm — C API for the zwasm WebAssembly runtime
 *
 * Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
 * See LICENSE at the root of this distribution.
 *
 * This is the single-header C interface. All types are opaque pointers.
 * Error handling: functions return NULL (pointer) or false (bool) on error.
 * Call zwasm_last_error_message() for a human-readable error description.
 *
 * Values are passed as uint64_t arrays matching the raw Wasm value encoding:
 *   i32: zero-extended to uint64_t
 *   i64: direct uint64_t
 *   f32: IEEE 754 bits zero-extended to uint64_t
 *   f64: IEEE 754 bits as uint64_t
 */

#ifndef ZWASM_H
#define ZWASM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
 * Opaque types
 * ================================================================ */

typedef struct zwasm_module_t zwasm_module_t;
typedef struct zwasm_config_t zwasm_config_t;
typedef struct zwasm_wasi_config_t zwasm_wasi_config_t;
typedef struct zwasm_imports_t zwasm_imports_t;

/* ================================================================
 * Host function callback
 * ================================================================ */

/**
 * Host function callback signature.
 *
 * @param env     User-provided context pointer (from zwasm_import_add_fn).
 * @param args    Input parameters as uint64_t array (param_count elements).
 * @param results Output buffer as uint64_t array (result_count elements).
 * @return true on success, false on error.
 */
typedef bool (*zwasm_host_fn_callback_t)(void *env, const uint64_t *args,
                                         uint64_t *results);

/* ================================================================
 * Error handling
 * ================================================================ */

/**
 * Return the last error message as a null-terminated string.
 * Returns "" if no error has occurred since the last successful call.
 * The pointer is valid until the next zwasm_* call on the same thread.
 */
const char *zwasm_last_error_message(void);

/* ================================================================
 * Configuration (optional)
 * ================================================================ */

/**
 * Custom allocator callback types.
 * alignment is in bytes (1, 2, 4, 8, ...).
 */
typedef void *(*zwasm_alloc_fn_t)(void *ctx, size_t size, size_t alignment);
typedef void (*zwasm_free_fn_t)(void *ctx, void *ptr, size_t size,
                                size_t alignment);

/** Create a new configuration handle. */
zwasm_config_t *zwasm_config_new(void);

/** Free a configuration handle. */
void zwasm_config_delete(zwasm_config_t *config);

/**
 * Set a custom allocator for module creation.
 * This controls zwasm's internal bookkeeping memory only.
 * Wasm linear memory (memory.grow) is unaffected.
 *
 * @param config    Configuration handle.
 * @param alloc_fn  Allocation callback: (ctx, size, alignment) -> ptr or NULL.
 * @param free_fn   Deallocation callback: (ctx, ptr, size, alignment).
 * @param ctx       User context pointer passed to callbacks.
 */
void zwasm_config_set_allocator(zwasm_config_t *config,
                                zwasm_alloc_fn_t alloc_fn,
                                zwasm_free_fn_t free_fn, void *ctx);

/* ================================================================
 * Module lifecycle
 * ================================================================ */

/**
 * Create a new Wasm module from binary bytes.
 * The wasm_ptr buffer can be freed after this call returns.
 * Returns NULL on error.
 */
zwasm_module_t *zwasm_module_new(const uint8_t *wasm_ptr, size_t len);

/**
 * Create a new WASI module from binary bytes.
 * Registers wasi_snapshot_preview1 imports with default capabilities.
 * Returns NULL on error.
 */
zwasm_module_t *zwasm_module_new_wasi(const uint8_t *wasm_ptr, size_t len);

/**
 * Create a new WASI module with custom configuration.
 * Returns NULL on error.
 */
zwasm_module_t *zwasm_module_new_wasi_configured(const uint8_t *wasm_ptr,
                                                  size_t len,
                                                  zwasm_wasi_config_t *config);

/**
 * Create a new module with host function imports.
 * Returns NULL on error.
 */
zwasm_module_t *zwasm_module_new_with_imports(const uint8_t *wasm_ptr,
                                               size_t len,
                                               zwasm_imports_t *imports);

/**
 * Create a module with optional configuration (custom allocator, etc.).
 * Pass NULL for config to use the default internal allocator.
 * Returns NULL on error.
 */
zwasm_module_t *zwasm_module_new_configured(const uint8_t *wasm_ptr, size_t len,
                                             zwasm_config_t *config);

/**
 * Create a WASI module with both WASI config and optional custom allocator.
 * Pass NULL for config to use the default internal allocator.
 * Returns NULL on error.
 */
zwasm_module_t *zwasm_module_new_wasi_configured2(const uint8_t *wasm_ptr,
                                                    size_t len,
                                                    zwasm_wasi_config_t *wasi_config,
                                                    zwasm_config_t *config);

/**
 * Free all resources held by a module.
 * After this call, the module pointer is invalid.
 */
void zwasm_module_delete(zwasm_module_t *module);

/**
 * Validate a Wasm binary without instantiation.
 * Returns true if valid, false if invalid or malformed.
 */
bool zwasm_module_validate(const uint8_t *wasm_ptr, size_t len);

/* ================================================================
 * Function invocation
 * ================================================================ */

/**
 * Invoke an exported function by name.
 *
 * @param module  Module handle.
 * @param name    Null-terminated function name.
 * @param args    Input parameters (nargs uint64_t values), or NULL if nargs==0.
 * @param nargs   Number of input parameters.
 * @param results Output buffer (nresults uint64_t values), or NULL if nresults==0.
 * @param nresults Number of expected results.
 * @return true on success, false on error.
 */
bool zwasm_module_invoke(zwasm_module_t *module, const char *name,
                         const uint64_t *args, uint32_t nargs,
                         uint64_t *results, uint32_t nresults);

/**
 * Invoke the _start function (WASI entry point).
 * Returns false on error.
 */
bool zwasm_module_invoke_start(zwasm_module_t *module);

/* ================================================================
 * Export introspection
 * ================================================================ */

/** Return the number of exported functions. */
uint32_t zwasm_module_export_count(zwasm_module_t *module);

/**
 * Return the name of the idx-th exported function.
 * Returns NULL if idx is out of range.
 * The pointer is valid until the next zwasm_module_export_name call.
 */
const char *zwasm_module_export_name(zwasm_module_t *module, uint32_t idx);

/** Return the parameter count of the idx-th exported function. */
uint32_t zwasm_module_export_param_count(zwasm_module_t *module, uint32_t idx);

/** Return the result count of the idx-th exported function. */
uint32_t zwasm_module_export_result_count(zwasm_module_t *module, uint32_t idx);

/* ================================================================
 * Memory access
 * ================================================================ */

/**
 * Return a direct pointer to linear memory (memory index 0).
 * Returns NULL if the module has no memory.
 * WARNING: Pointer is invalidated by memory growth.
 */
uint8_t *zwasm_module_memory_data(zwasm_module_t *module);

/** Return the current size of linear memory in bytes. */
size_t zwasm_module_memory_size(zwasm_module_t *module);

/**
 * Read bytes from linear memory into out_buf.
 * Returns false on out-of-bounds access.
 */
bool zwasm_module_memory_read(zwasm_module_t *module, uint32_t offset,
                              uint32_t len, uint8_t *out_buf);

/**
 * Write bytes from data into linear memory.
 * Returns false on out-of-bounds access.
 */
bool zwasm_module_memory_write(zwasm_module_t *module, uint32_t offset,
                               const uint8_t *data, uint32_t len);

/* ================================================================
 * WASI configuration
 * ================================================================ */

/** Create a new WASI configuration handle. */
zwasm_wasi_config_t *zwasm_wasi_config_new(void);

/** Free a WASI configuration handle. */
void zwasm_wasi_config_delete(zwasm_wasi_config_t *config);

/** Set command-line arguments. argv entries are null-terminated C strings. */
void zwasm_wasi_config_set_argv(zwasm_wasi_config_t *config, uint32_t argc,
                                const char *const *argv);

/**
 * Set environment variables.
 * keys/vals are arrays of pointers; key_lens/val_lens are their lengths.
 */
void zwasm_wasi_config_set_env(zwasm_wasi_config_t *config, uint32_t count,
                               const char *const *keys,
                               const size_t *key_lens,
                               const char *const *vals,
                               const size_t *val_lens);

/** Add a preopened directory mapping. */
void zwasm_wasi_config_preopen_dir(zwasm_wasi_config_t *config,
                                   const char *host_path, size_t host_path_len,
                                   const char *guest_path,
                                   size_t guest_path_len);

/**
 * Add a preopened entry from an existing host file descriptor.
 *
 * @param config      WASI config handle.
 * @param host_fd     Open host file descriptor.
 * @param guest_path  Guest-visible path.
 * @param guest_path_len Length of guest_path.
 * @param kind        0 = file, 1 = directory.
 * @param ownership   0 = borrow (caller retains fd), 1 = own (runtime closes fd).
 */
void zwasm_wasi_config_preopen_fd(zwasm_wasi_config_t *config,
                                  int host_fd,
                                  const char *guest_path,
                                  size_t guest_path_len,
                                  uint8_t kind, uint8_t ownership);

/**
 * Override a stdio file descriptor (0=stdin, 1=stdout, 2=stderr).
 *
 * @param config      WASI config handle.
 * @param wasi_fd     0, 1, or 2.
 * @param host_fd     Open host file descriptor.
 * @param ownership   0 = borrow (caller retains fd), 1 = own (runtime closes fd).
 */
void zwasm_wasi_config_set_stdio_fd(zwasm_wasi_config_t *config,
                                    uint32_t wasi_fd,
                                    int host_fd, uint8_t ownership);

/* ================================================================
 * Host function imports
 * ================================================================ */

/** Create a new import collection. */
zwasm_imports_t *zwasm_import_new(void);

/** Free an import collection. */
void zwasm_import_delete(zwasm_imports_t *imports);

/**
 * Register a host function in the import collection.
 *
 * @param imports      Import collection handle.
 * @param module_name  Null-terminated Wasm module name (e.g., "env").
 * @param func_name    Null-terminated function name.
 * @param callback     C callback function.
 * @param env          User context pointer passed to callback.
 * @param param_count  Number of parameters the function expects.
 * @param result_count Number of results the function returns.
 */
void zwasm_import_add_fn(zwasm_imports_t *imports, const char *module_name,
                         const char *func_name,
                         zwasm_host_fn_callback_t callback, void *env,
                         uint32_t param_count, uint32_t result_count);

#ifdef __cplusplus
}
#endif

#endif /* ZWASM_H */
