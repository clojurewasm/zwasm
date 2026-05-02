# OrbStack Ubuntu x86_64 VM Setup

One-time setup for local Ubuntu x86_64 testing via OrbStack on
Apple Silicon. The VM runs x86_64 Ubuntu under Rosetta translation;
this catches most arch-asymmetric regressions (W54-class) at the
ELF / SystemV-ABI / x86 ISA level. For deepest validation against
**native** x86_64 hardware, use the `windowsmini` SSH host (see
`.dev/windows_ssh_setup.md`); CI matrix ubuntu-22.04 (Phase 14+)
also runs on native x86_64.

## VM Creation

```bash
orb create --arch amd64 ubuntu my-ubuntu-amd64
```

VM name: `my-ubuntu-amd64` (shared with the v1 setup; reuse the
existing VM if already present).

## Tool Installation

Run inside the VM:

```bash
orb run -m my-ubuntu-amd64 bash -lc "<commands>"
```

The minimum tool surface needed for Phase 0 is **Zig 0.16.0**.
Other tools are added when the corresponding Phase opens.

```bash
# System packages
sudo apt update && sudo apt install -y build-essential python3 xz-utils curl git rsync

# Zig 0.16.0
curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
sudo mkdir -p /opt/zig && sudo tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc

# (Phase 1+) wasm-tools and wasm-c-api are pulled by scripts when needed.
# (Phase 4+) wasmtime, WASI SDK, Rust + wasm32-wasip1 — added on demand.
# (Phase 11+) hyperfine — added on demand.
```

## Build verification (§9.0 / 0.2)

From Mac, in `zwasm_from_scratch/`:

```bash
orb run -m my-ubuntu-amd64 bash -c '
  cd /Users/shota.508/Documents/MyProducts/zwasm_from_scratch &&
  zig build &&
  zig build test
'
```

(OrbStack mounts the Mac home directory inside the VM at the same
path; building from the Mac FS is slow but correct. For benchmarks
where build time matters, rsync to the VM's local storage.)

## Notes on Rosetta

OrbStack on Apple Silicon emulates x86_64 via Rosetta. Most
arch-asymmetric bugs that v1's W54 surfaced are caught here, but
Rosetta has its own quirks (FP rounding, signal-handler edge cases).
The ROADMAP §11.5 three-host gate (Mac native + OrbStack +
windowsmini) gives the deepest local coverage; CI matrix from
Phase 14 adds GitHub-hosted ubuntu-22.04 (true native x86_64).

## Future improvements

- Replace the manual `apt install` / `curl` recipe with Nix devshell
  + direnv inside the VM, mirroring the Mac-host setup.
- Pin tool versions via a `versions.lock` file once CI is wired (Phase 14+).
