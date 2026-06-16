#!/usr/bin/env python3
# Distil a `wasm-tools json-from-wast` JSON into the NATIVE-engine spec
# runner manifest format (`test/spec/wasm_3_0_manifest.zig` directive set):
#
#   module [$id] <path>
#   assert_return <field> <args|()> -> <results|()>
#   assert_trap   <field> <args|()>          (no trap-kind tag)
#   assert_invalid|assert_malformed|assert_uninstantiable|assert_unlinkable <path>
#   invoke <field> <args>
#   register <name>
#   skip-impl|skip-adr-... <reason>
#
# Values are `<type>:<decimal>` (i32/i64 signed-folded to unsigned;
# v128/ref types passed through as the runner expects — D-222).
#
# This is the NATIVE-runner counterpart to scripts/wast_to_manifest.py
# (which targets the C-API runtime runner). Logic factored from the inline
# baker in scripts/regen_spec_3_0_assert.sh so the wasmtime-misc native
# differential sweep (ADR-0192, scripts/wasmtime_misc_native_sweep.sh) and
# the committed-corpus regen share one converter.
#
# Usage: wast_to_native_manifest.py <src.json> <dst_manifest>
import json
import sys


def fmt(v):
    val = v.get('value', '?')
    t = v['type']
    if t == 'i32' and isinstance(val, str) and val.startswith('-'):
        n = int(val)
        if n < 0:
            val = str(n + (1 << 32))
    elif t == 'i64' and isinstance(val, str) and val.startswith('-'):
        n = int(val)
        if n < 0:
            val = str(n + (1 << 64))
    return f"{t}:{val}"


def norm_mid(mid):
    if mid and not mid.startswith('$'):
        return '$' + mid
    return mid


def distil(src):
    return distil_doc(json.load(open(src)))


def distil_doc(d):
    lines = []
    for c in d['commands']:
        t = c.get('type')
        if t == 'module':
            mname = norm_mid(c.get('name'))
            if mname:
                lines.append('module ' + mname + ' ' + c['filename'])
            else:
                lines.append('module ' + c['filename'])
        elif t == 'assert_return':
            a = c['action']
            if a.get('type') != 'invoke':
                lines.append('skip-impl non-invoke-action')
                continue
            amod = norm_mid(a.get('module'))
            field_tok = (amod + '::' + a['field']) if amod else a['field']
            args = a.get('args', [])
            results = c.get('expected', [])
            args_s = ' '.join(fmt(x) for x in args) if args else '()'
            results_s = ' '.join(fmt(x) for x in results) if results else '()'
            lines.append(f'assert_return {field_tok} {args_s} -> {results_s}')
        elif t == 'assert_trap':
            a = c['action']
            amod = norm_mid(a.get('module'))
            field_raw = a.get('field', '<non-invoke>')
            field_tok = (amod + '::' + field_raw) if amod else field_raw
            args = a.get('args', []) if a.get('type') == 'invoke' else []
            args_s = ' '.join(fmt(x) for x in args) if args else '()'
            lines.append(f'assert_trap {field_tok} {args_s}')
        elif t == 'assert_invalid':
            lines.append(f'assert_invalid {c.get("filename", "<inline>")}')
        elif t == 'assert_uninstantiable':
            if 'filename' in c:
                lines.append(f'assert_uninstantiable {c["filename"]}')
            else:
                lines.append('skip-impl directive-assert_uninstantiable-inline')
        elif t == 'assert_unlinkable':
            if 'filename' in c:
                lines.append(f'assert_unlinkable {c["filename"]}')
            else:
                lines.append('skip-impl directive-assert_unlinkable-inline')
        elif t == 'assert_malformed':
            if c.get('module_type') == 'binary' and 'filename' in c:
                lines.append(f'assert_malformed {c["filename"]}')
            else:
                lines.append('skip-adr-skip_text_format_parser directive-assert_malformed-text')
        elif t == 'assert_exception':
            a = c.get('action', {})
            args = a.get('args', []) if a.get('type') == 'invoke' else []
            args_s = ' '.join(fmt(x) for x in args) if args else '()'
            field = a.get('field', '<non-invoke>')
            lines.append(f'assert_exception {field} {args_s}')
        elif t == 'action':
            a = c.get('action', {})
            if a.get('type') != 'invoke':
                lines.append('skip-impl non-invoke-action')
                continue
            amod = norm_mid(a.get('module'))
            field_tok = (amod + '::' + a['field']) if amod else a['field']
            args = a.get('args', [])
            args_s = ' '.join(fmt(x) for x in args) if args else '()'
            lines.append(f'invoke {field_tok} {args_s}')
        elif t == 'register':
            lines.append(f'register {c.get("as", "?")}')
        else:
            lines.append(f'skip-impl directive-{t}')
    return lines


def _selftest():
    out = distil_doc({'commands': [
        {'type': 'module', 'filename': 'm.0.wasm'},
        {'type': 'module', 'name': 'M', 'filename': 'm.1.wasm'},
        {'type': 'assert_return', 'action': {'type': 'invoke', 'field': 'f',
            'args': [{'type': 'i32', 'value': '-1'}]},
            'expected': [{'type': 'i64', 'value': '-2'}]},
        {'type': 'assert_trap', 'action': {'type': 'invoke', 'field': 'g', 'args': []}},
        {'type': 'register', 'as': 'lib'},
    ]})
    assert out[0] == 'module m.0.wasm', out[0]
    assert out[1] == 'module $M m.1.wasm', out[1]
    assert out[2] == 'assert_return f i32:4294967295 -> i64:18446744073709551614', out[2]
    assert out[3] == 'assert_trap g ()', out[3]
    assert out[4] == 'register lib', out[4]
    print("wast_to_native_manifest selftest: {} cases OK".format(len(out)))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    lines = distil(src)
    with open(dst, 'w') as f:
        f.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    if len(sys.argv) == 1:
        _selftest()
    else:
        main()
