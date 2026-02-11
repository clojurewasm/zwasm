#!/usr/bin/env python3
"""Generate custom-page-sizes e2e test files (JSON + wasm).

wast2json does not support the (pagesize N) syntax, so we generate
the test files directly from binary encoding.

Usage: python3 test/e2e/gen_custom_page_sizes.py
"""
import json
import os

JSON_DIR = os.path.join(os.path.dirname(__file__), "json")


def leb128_u32(val):
    result = bytearray()
    while True:
        byte = val & 0x7F
        val >>= 7
        if val:
            byte |= 0x80
        result.append(byte)
        if not val:
            break
    return bytes(result)


def build_section(section_id, payload):
    return bytes([section_id]) + leb128_u32(len(payload)) + payload


def build_module_page1_min0():
    """Module 0: memory (page_size=1, min=0) with size/grow/load/store."""
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')

    # Type section: 3 types
    tb = bytearray()
    tb += leb128_u32(3)
    tb += bytes([0x60, 0x00, 0x01, 0x7f])        # () -> (i32)
    tb += bytes([0x60, 0x01, 0x7f, 0x01, 0x7f])  # (i32) -> (i32)
    tb += bytes([0x60, 0x02, 0x7f, 0x7f, 0x00])  # (i32,i32) -> ()
    buf += build_section(0x01, tb)

    # Function section: 4 funcs
    fb = bytearray()
    fb += leb128_u32(4)
    for t in [0, 1, 1, 2]:
        fb += leb128_u32(t)
    buf += build_section(0x03, fb)

    # Memory section: page_size=1, min=0
    mb = bytearray()
    mb += leb128_u32(1)
    mb += bytes([0x08])   # flags: custom page size
    mb += leb128_u32(0)   # min = 0
    mb += leb128_u32(0)   # page_exp = 0 (2^0 = 1)
    buf += build_section(0x05, mb)

    # Export section
    eb = bytearray()
    names = [b'size', b'grow', b'load', b'store']
    eb += leb128_u32(len(names))
    for i, name in enumerate(names):
        eb += leb128_u32(len(name)) + name
        eb += bytes([0x00]) + leb128_u32(i)
    buf += build_section(0x07, eb)

    # Code section
    bodies = [
        bytearray([0x00, 0x3f, 0x00, 0x0b]),                          # size
        bytearray([0x00, 0x20, 0x00, 0x40, 0x00, 0x0b]),              # grow
        bytearray([0x00, 0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b]),        # load
        bytearray([0x00, 0x20, 0x00, 0x20, 0x01, 0x3a, 0x00, 0x00, 0x0b]),  # store
    ]
    cb = bytearray()
    cb += leb128_u32(len(bodies))
    for b in bodies:
        cb += leb128_u32(len(b)) + b
    buf += build_section(0x0a, cb)

    return bytes(buf)


def build_module_page65536_min0():
    """Module 1: memory (page_size=65536 explicit, min=0) with size/grow."""
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')

    # Type section
    tb = bytearray()
    tb += leb128_u32(2)
    tb += bytes([0x60, 0x00, 0x01, 0x7f])        # () -> (i32)
    tb += bytes([0x60, 0x01, 0x7f, 0x01, 0x7f])  # (i32) -> (i32)
    buf += build_section(0x01, tb)

    # Function section: 2 funcs
    fb = bytearray()
    fb += leb128_u32(2)
    fb += leb128_u32(0)  # size
    fb += leb128_u32(1)  # grow
    buf += build_section(0x03, fb)

    # Memory: page_size=65536 explicit, min=0
    mb = bytearray()
    mb += leb128_u32(1)
    mb += bytes([0x08])    # flags: custom page size
    mb += leb128_u32(0)    # min = 0
    mb += leb128_u32(16)   # page_exp = 16 (2^16 = 65536)
    buf += build_section(0x05, mb)

    # Export
    eb = bytearray()
    names = [b'size', b'grow']
    eb += leb128_u32(len(names))
    for i, name in enumerate(names):
        eb += leb128_u32(len(name)) + name
        eb += bytes([0x00]) + leb128_u32(i)
    buf += build_section(0x07, eb)

    # Code
    bodies = [
        bytearray([0x00, 0x3f, 0x00, 0x0b]),              # size
        bytearray([0x00, 0x20, 0x00, 0x40, 0x00, 0x0b]),  # grow
    ]
    cb = bytearray()
    cb += leb128_u32(len(bodies))
    for b in bodies:
        cb += leb128_u32(len(b)) + b
    buf += build_section(0x0a, cb)

    return bytes(buf)


def build_module_page1_min8_i64load():
    """Module 2: memory (page_size=1, min=8) with load64 for alignment test."""
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')

    # Type section
    tb = bytearray()
    tb += leb128_u32(1)
    tb += bytes([0x60, 0x01, 0x7f, 0x01, 0x7e])  # (i32) -> (i64)
    buf += build_section(0x01, tb)

    # Function section
    fb = bytearray()
    fb += leb128_u32(1)
    fb += leb128_u32(0)
    buf += build_section(0x03, fb)

    # Memory: page_size=1, min=8
    mb = bytearray()
    mb += leb128_u32(1)
    mb += bytes([0x08, 0x08, 0x00])  # flags=0x08, min=8, page_exp=0
    buf += build_section(0x05, mb)

    # Export
    eb = bytearray()
    eb += leb128_u32(1)
    name = b'load64'
    eb += leb128_u32(len(name)) + name
    eb += bytes([0x00, 0x00])
    buf += build_section(0x07, eb)

    # Code: local.get 0, i64.load align=0 offset=0, end
    body = bytearray([0x00, 0x20, 0x00, 0x29, 0x00, 0x00, 0x0b])
    cb = bytearray()
    cb += leb128_u32(1)
    cb += leb128_u32(len(body)) + body
    buf += build_section(0x0a, cb)

    return bytes(buf)


def build_module_valid_page1():
    """Module 3: just validates (memory 1 (pagesize 1))."""
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')
    mb = bytearray()
    mb += leb128_u32(1)
    mb += bytes([0x08, 0x01, 0x00])  # flags=0x08, min=1, page_exp=0
    buf += build_section(0x05, mb)
    return bytes(buf)


def build_module_valid_page65536():
    """Module 4: just validates (memory 1 (pagesize 65536))."""
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')
    mb = bytearray()
    mb += leb128_u32(1)
    mb += bytes([0x08, 0x01, 0x10])  # flags=0x08, min=1, page_exp=16
    buf += build_section(0x05, mb)
    return bytes(buf)


def build_module_valid_page1_with_max():
    """Module 5: (memory 1 2 (pagesize 1))."""
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')
    mb = bytearray()
    mb += leb128_u32(1)
    mb += bytes([0x09])   # flags: has_max + custom page size
    mb += leb128_u32(1)   # min=1
    mb += leb128_u32(2)   # max=2
    mb += leb128_u32(0)   # page_exp=0
    buf += build_section(0x05, mb)
    return bytes(buf)


def main():
    os.makedirs(JSON_DIR, exist_ok=True)

    modules = [
        ("custom-page-sizes.0.wasm", build_module_page1_min0()),
        ("custom-page-sizes.1.wasm", build_module_page65536_min0()),
        ("custom-page-sizes.2.wasm", build_module_page1_min8_i64load()),
        ("custom-page-sizes.3.wasm", build_module_valid_page1()),
        ("custom-page-sizes.4.wasm", build_module_valid_page65536()),
        ("custom-page-sizes.5.wasm", build_module_valid_page1_with_max()),
    ]

    for name, data in modules:
        with open(os.path.join(JSON_DIR, name), "wb") as f:
            f.write(data)

    commands = []

    # Module 3: validate (memory 1 (pagesize 1))
    commands.append({"type": "module", "line": 5,
                     "filename": "custom-page-sizes.3.wasm"})
    # Module 4: validate (memory 1 (pagesize 65536))
    commands.append({"type": "module", "line": 6,
                     "filename": "custom-page-sizes.4.wasm"})
    # Module 5: validate (memory 1 2 (pagesize 1))
    commands.append({"type": "module", "line": 9,
                     "filename": "custom-page-sizes.5.wasm"})

    # Module 0: page_size=1 comprehensive test
    commands.append({"type": "module", "line": 13,
                     "filename": "custom-page-sizes.0.wasm"})

    def ar(field, args, expected, line):
        return {
            "type": "assert_return", "line": line,
            "action": {"type": "invoke", "field": field,
                       "args": [{"type": "i32", "value": str(a)} for a in args]},
            "expected": [{"type": "i32", "value": str(e)} for e in expected],
        }

    def at(field, args, text, line):
        return {
            "type": "assert_trap", "line": line,
            "action": {"type": "invoke", "field": field,
                       "args": [{"type": "i32", "value": str(a)} for a in args]},
            "text": text,
        }

    # (assert_return (invoke "size") (i32.const 0))
    commands.append(ar("size", [], [0], 29))
    # (assert_trap (invoke "load" (i32.const 0)) "out of bounds memory access")
    commands.append(at("load", [0], "out of bounds memory access", 30))

    # Grow by 65536, old size = 0
    commands.append(ar("grow", [65536], [0], 32))
    commands.append(ar("size", [], [65536], 33))
    commands.append(ar("load", [65535], [0], 34))
    commands.append(ar("store", [65535, 1], [], 35))
    commands.append(ar("load", [65535], [1], 36))
    commands.append(at("load", [65536], "out of bounds memory access", 37))

    # Grow again by 65536
    commands.append(ar("grow", [65536], [65536], 39))
    commands.append(ar("size", [], [131072], 40))
    commands.append(ar("load", [131071], [0], 41))
    commands.append(ar("store", [131071, 1], [], 42))
    commands.append(ar("load", [131071], [1], 43))
    commands.append(at("load", [131072], "out of bounds memory access", 44))

    # Module 1: page_size=65536 (explicit), can't grow past 65536 pages
    commands.append({"type": "module", "line": 49,
                     "filename": "custom-page-sizes.1.wasm"})
    commands.append(ar("size", [], [0], 58))

    # 65537 pages would overflow: (65537 * 65536 > 4GiB)
    MINUS_ONE = 4294967295  # -1 as u32
    commands.append(ar("grow", [65537], [MINUS_ONE], 59))
    commands.append(ar("size", [], [0], 60))

    # Module 2: page_size=1, min=8, i64.load at offset 0
    commands.append({"type": "module", "line": 113,
                     "filename": "custom-page-sizes.2.wasm"})
    commands.append(ar("load64", [0], [0], 121))

    json_data = {
        "source_filename": "test/e2e/gen_custom_page_sizes.py",
        "commands": commands,
    }

    with open(os.path.join(JSON_DIR, "custom-page-sizes.json"), "w") as f:
        json.dump(json_data, f, indent=2)

    n_modules = sum(1 for c in commands if c['type'] == 'module')
    n_asserts = sum(1 for c in commands if c['type'] in ('assert_return', 'assert_trap'))
    print(f"custom-page-sizes: {n_modules} modules, {n_asserts} assertions")


if __name__ == "__main__":
    main()
