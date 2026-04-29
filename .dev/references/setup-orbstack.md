# OrbStack Ubuntu x86_64 VM Setup

One-time setup for local Ubuntu x86_64 testing via OrbStack on Apple Silicon.

## VM Creation

```bash
orb create --arch amd64 ubuntu my-ubuntu-amd64
```

## Tool Installation

Run inside the VM (`orb run -m my-ubuntu-amd64 bash -lc "..."`):

```bash
# System packages
sudo apt update && sudo apt install -y build-essential python3 xz-utils curl git rsync

# Versions are pinned in .github/versions.lock — adjust below when bumping.
# `source` it inside the VM if you want the literal version constants:
#   source ~/zwasm/.github/versions.lock
# Then ${ZIG_VERSION}, ${WASMTIME_VERSION}, ${WASM_TOOLS_VERSION},
# ${WASI_SDK_VERSION} are available.

# Zig 0.16.0
curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
sudo mkdir -p /opt/zig && sudo tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc

# wasmtime 42.0.1
curl https://wasmtime.dev/install.sh -sSf | bash
echo 'export PATH="$HOME/.wasmtime/bin:$PATH"' >> ~/.bashrc

# wasm-tools 1.246.1
curl -L -o /tmp/wasm-tools.tar.gz \
  https://github.com/bytecodealliance/wasm-tools/releases/download/v1.246.1/wasm-tools-1.246.1-x86_64-linux.tar.gz
sudo tar -xzf /tmp/wasm-tools.tar.gz -C /usr/local/bin --strip-components=1 \
  wasm-tools-1.246.1-x86_64-linux/wasm-tools

# WASI SDK 30
curl -L -o /tmp/wasi-sdk.tar.gz \
  https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-x86_64-linux.tar.gz
sudo mkdir -p /opt/wasi-sdk && sudo tar -xzf /tmp/wasi-sdk.tar.gz -C /opt/wasi-sdk --strip-components=1
echo 'export WASI_SDK_PATH="/opt/wasi-sdk"' >> ~/.bashrc

# Rust + wasm32-wasip1
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add wasm32-wasip1

# hyperfine (benchmarks)
sudo apt install -y hyperfine

# wasmtime source (for E2E misc_testsuite)
mkdir -p ~/Documents/OSS
git clone --depth 1 https://github.com/bytecodealliance/wasmtime.git ~/Documents/OSS/wasmtime
```

## Installed Tool Versions

| Tool       | Version  | Path                     |
| ---------- | -------- | ------------------------ |
| Zig        | 0.16.0   | /opt/zig/zig             |
| wasmtime   | 42.0.1   | ~/.wasmtime/bin/wasmtime |
| wasm-tools | 1.246.1  | /usr/local/bin/wasm-tools|
| WASI SDK   | 30       | /opt/wasi-sdk            |
| Rust       | stable   | ~/.cargo/bin/rustc       |
| hyperfine  | system   | /usr/bin/hyperfine       |

Pinned versions live in `.github/versions.lock` (mirror of `flake.nix`);
update both when bumping. A future Plan B sub-3 follow-up will replace
this manual install recipe with Nix devshell + direnv inside the VM
(see W50 in `.dev/checklist.md`).

## Notes

- VM name: `my-ubuntu-amd64` (shared between zwasm and ClojureWasm)
- Mac filesystem accessible inside VM at original paths (e.g., `/Users/shota.508/...`)
  but building directly from Mac FS is slow — rsync to VM-local storage instead
- OrbStack uses Rosetta for x86_64 emulation on Apple Silicon
