#!/usr/bin/env python3
"""
basic.py — Python ctypes example for zwasm C API

Demonstrates: load module, invoke function, read memory.

Usage:
  # Build the shared library first:
  zig build lib
  # Then run:
  python3 examples/python/basic.py
"""

import ctypes
import os
import sys

def find_library():
    """Find libzwasm shared library."""
    base = os.path.dirname(os.path.abspath(__file__))
    root = os.path.join(base, "..", "..")

    candidates = [
        os.path.join(root, "zig-out", "lib", "libzwasm.dylib"),
        os.path.join(root, "zig-out", "lib", "libzwasm.so"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


def main():
    lib_path = find_library()
    if not lib_path:
        print("Error: libzwasm not found. Run 'zig build lib' first.", file=sys.stderr)
        sys.exit(1)

    lib = ctypes.CDLL(lib_path)

    # Set up function signatures
    lib.zwasm_module_new.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    lib.zwasm_module_new.restype = ctypes.c_void_p

    lib.zwasm_module_delete.argtypes = [ctypes.c_void_p]
    lib.zwasm_module_delete.restype = None

    lib.zwasm_module_invoke.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32,
    ]
    lib.zwasm_module_invoke.restype = ctypes.c_bool

    lib.zwasm_module_memory_data.argtypes = [ctypes.c_void_p]
    lib.zwasm_module_memory_data.restype = ctypes.POINTER(ctypes.c_uint8)

    lib.zwasm_module_memory_size.argtypes = [ctypes.c_void_p]
    lib.zwasm_module_memory_size.restype = ctypes.c_size_t

    lib.zwasm_last_error_message.argtypes = []
    lib.zwasm_last_error_message.restype = ctypes.c_char_p

    # Wasm module: export "f" () -> i32 { return 42 }
    wasm_bytes = bytes([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
    ])

    # Load module
    mod = lib.zwasm_module_new(wasm_bytes, len(wasm_bytes))
    if not mod:
        print(f"Error: {lib.zwasm_last_error_message().decode()}")
        sys.exit(1)

    # Invoke "f"
    results = (ctypes.c_uint64 * 1)(0)
    ok = lib.zwasm_module_invoke(mod, b"f", None, 0, results, 1)
    if not ok:
        print(f"Invoke error: {lib.zwasm_last_error_message().decode()}")
        lib.zwasm_module_delete(mod)
        sys.exit(1)

    print(f"f() = {results[0]}")
    assert results[0] == 42, f"Expected 42, got {results[0]}"

    # Cleanup
    lib.zwasm_module_delete(mod)
    print("All Python ctypes tests passed!")


if __name__ == "__main__":
    main()
