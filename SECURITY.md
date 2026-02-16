# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| main branch | Yes |
| Tagged releases (v0.x.x) | Yes |

## Reporting a Vulnerability

If you discover a security vulnerability in zwasm, please report it responsibly:

1. **Do NOT open a public GitHub issue** for security vulnerabilities
2. Email: **shota.508+zwasm-security@gmail.com**
3. Include:
   - Description of the vulnerability
   - Steps to reproduce (Wasm module or test case if possible)
   - Impact assessment (crash, memory corruption, sandbox escape, etc.)
   - Affected component (decoder, validator, JIT, WASI, etc.)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix or mitigation**: Depends on severity
  - Critical (sandbox escape, RCE): As fast as possible
  - High (crash, denial of service): Within 2 weeks
  - Medium/Low: Next release cycle

## Scope

The following are in scope for security reports:

- Linear memory escape (reading/writing outside Wasm memory bounds)
- Table bounds or type confusion attacks
- JIT code injection or W^X violations
- WASI capability bypass (accessing resources without capability)
- Sandbox escape (guest code affecting host beyond defined API)
- Crash from valid or invalid Wasm modules (fuzzer-reproducible)
- Stack overflow/underflow leading to memory corruption

The following are out of scope:

- Denial of service via resource exhaustion (by design, no CPU/memory quotas)
- Timing side channels
- Issues only reproducible with ReleaseFast (use ReleaseSafe for production)
- Bugs in host-provided import functions

## Security Model

See [docs/security.md](docs/security.md) for the full threat model, including
what zwasm protects against and what it does not.

## Build Recommendations

For production use with untrusted Wasm modules:

```bash
zig build -Doptimize=ReleaseSafe
```

ReleaseSafe preserves bounds checks, overflow detection, and safety assertions.
Do NOT use ReleaseFast for untrusted code — it strips safety checks.
