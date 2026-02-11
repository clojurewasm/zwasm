#!/usr/bin/env python3
"""Generate wide-arithmetic e2e test files (JSON + wasm).

wast2json 1.0.39 does not support wide arithmetic opcodes, so we generate
the test files directly from the .wast source.

Usage: python3 test/e2e/gen_wide_arithmetic.py
"""
import json, re, os, struct

WAST_PATH = os.path.join(os.path.dirname(__file__), "wast", "wide-arithmetic.wast")
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


def build_wasm_module(funcs):
    """Build a wasm module from function definitions.

    Each func: {'name': str, 'params': int, 'results': int, 'body': bytes}
    All params/results are i64.
    """
    buf = bytearray(b'\x00asm\x01\x00\x00\x00')

    # Collect unique signatures
    sigs = []
    func_sig_idx = []
    for f in funcs:
        sig = (f['params'], f['results'])
        if sig not in sigs:
            sigs.append(sig)
        func_sig_idx.append(sigs.index(sig))

    # Type section
    tb = bytearray()
    tb += leb128_u32(len(sigs))
    for np, nr in sigs:
        tb.append(0x60)
        tb += leb128_u32(np)
        tb += bytes([0x7E] * np)
        tb += leb128_u32(nr)
        tb += bytes([0x7E] * nr)
    buf += bytes([0x01]) + leb128_u32(len(tb)) + tb

    # Function section
    fb = bytearray()
    fb += leb128_u32(len(funcs))
    for idx in func_sig_idx:
        fb += leb128_u32(idx)
    buf += bytes([0x03]) + leb128_u32(len(fb)) + fb

    # Export section
    eb = bytearray()
    eb += leb128_u32(len(funcs))
    for i, f in enumerate(funcs):
        name = f['name'].encode()
        eb += leb128_u32(len(name)) + name
        eb += bytes([0x00]) + leb128_u32(i)
    buf += bytes([0x07]) + leb128_u32(len(eb)) + eb

    # Code section
    bodies = []
    for f in funcs:
        body = bytearray([0x00])  # 0 locals
        body += f['body']
        body.append(0x0B)  # end
        bodies.append(body)

    cb = bytearray()
    cb += leb128_u32(len(bodies))
    for b in bodies:
        cb += leb128_u32(len(b)) + b
    buf += bytes([0x0A]) + leb128_u32(len(cb)) + cb

    return bytes(buf)


def local_get(n):
    return bytes([0x20]) + leb128_u32(n)


def i64_const_0():
    return bytes([0x42, 0x00])


def parse_i64_value(s):
    val = int(s)
    if val < 0:
        val += (1 << 64)
    return str(val)


def main():
    if not os.path.exists(WAST_PATH):
        print(f"ERROR: {WAST_PATH} not found")
        return

    os.makedirs(JSON_DIR, exist_ok=True)

    # Module 0: all 4 wide arithmetic functions (params passed directly)
    m0_funcs = [
        {'name': 'i64.add128', 'params': 4, 'results': 2,
         'body': local_get(0) + local_get(1) + local_get(2) + local_get(3) + bytes([0xFC, 0x13])},
        {'name': 'i64.sub128', 'params': 4, 'results': 2,
         'body': local_get(0) + local_get(1) + local_get(2) + local_get(3) + bytes([0xFC, 0x14])},
        {'name': 'i64.mul_wide_s', 'params': 2, 'results': 2,
         'body': local_get(0) + local_get(1) + bytes([0xFC, 0x15])},
        {'name': 'i64.mul_wide_u', 'params': 2, 'results': 2,
         'body': local_get(0) + local_get(1) + bytes([0xFC, 0x16])},
    ]
    wasm0 = build_wasm_module(m0_funcs)
    with open(os.path.join(JSON_DIR, "wide-arithmetic.0.wasm"), "wb") as f:
        f.write(wasm0)

    # Module 1: u64::overflowing_add — wraps add128 as (a, b) -> (lo, carry)
    m1_funcs = [
        {'name': 'u64::overflowing_add', 'params': 2, 'results': 2,
         'body': local_get(0) + i64_const_0() + local_get(1) + i64_const_0() + bytes([0xFC, 0x13])},
    ]
    wasm1 = build_wasm_module(m1_funcs)
    with open(os.path.join(JSON_DIR, "wide-arithmetic.1.wasm"), "wb") as f:
        f.write(wasm1)

    # Parse wast file for assertions
    with open(WAST_PATH) as f:
        content = f.read()

    commands = []
    lines = content.split('\n')
    i = 0
    module_idx = 0

    while i < len(lines):
        line_num = i + 1
        line = lines[i].strip()

        if line.startswith('(module'):
            commands.append({"type": "module", "line": line_num,
                            "filename": f"wide-arithmetic.{module_idx}.wasm"})
            module_idx += 1
            i += 1
            continue

        if line.startswith('(assert_return'):
            full = line
            while full.count('(') > full.count(')'):
                i += 1
                if i < len(lines):
                    full += ' ' + lines[i].strip()

            # Split invoke part from expected part by matching parens
            invoke_start = full.index('(invoke')
            depth = 0
            invoke_end = invoke_start
            for j in range(invoke_start, len(full)):
                if full[j] == '(':
                    depth += 1
                elif full[j] == ')':
                    depth -= 1
                    if depth == 0:
                        invoke_end = j + 1
                        break

            invoke_part = full[invoke_start:invoke_end]
            expected_part = full[invoke_end:]

            m = re.search(r'"([^"]+)"', invoke_part)
            func_name = m.group(1) if m else ""

            name_end = invoke_part.index('"', invoke_part.index('"') + 1) + 1
            args_str = invoke_part[name_end:]
            args = [{"type": "i64", "value": parse_i64_value(am.group(1))}
                    for am in re.finditer(r'\(i64\.const\s+(-?\d+)\)', args_str)]
            expected = [{"type": "i64", "value": parse_i64_value(em.group(1))}
                       for em in re.finditer(r'\(i64\.const\s+(-?\d+)\)', expected_part)]

            commands.append({
                "type": "assert_return",
                "line": line_num,
                "action": {"type": "invoke", "field": func_name, "args": args},
                "expected": expected
            })
        i += 1

    json_data = {
        "source_filename": "test/e2e/wast/wide-arithmetic.wast",
        "commands": commands
    }

    with open(os.path.join(JSON_DIR, "wide-arithmetic.json"), "w") as f:
        json.dump(json_data, f, indent=2)

    n_modules = sum(1 for c in commands if c['type'] == 'module')
    n_asserts = sum(1 for c in commands if c['type'] == 'assert_return')
    print(f"wide-arithmetic: {n_modules} modules, {n_asserts} assertions")


if __name__ == "__main__":
    main()
