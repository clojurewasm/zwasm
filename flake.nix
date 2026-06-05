{
  description = "zwasm v2 — a from-scratch WebAssembly runtime in Zig 0.16.0";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Realworld-fixture generation only (devShells.gen). Pins the Rust
    # toolchain with wasm targets. Kept out of `devShells.default` so the
    # test hosts (ubuntu / windows via SSH) never pull it.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # `default` shell uses plain legacyPackages — unchanged, load-bearing
        # for every host. Do NOT add generation toolchains here.
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";

        # `gen` shell uses a rust-overlay-enabled package set. Separate
        # binding so the overlay never perturbs `default`.
        genPkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        # `.minimal` = rustc + cargo + rust-std only (no docs/clippy/rustfmt,
        # which build from source and aren't needed to compile wasm fixtures).
        rustWasm = genPkgs.rust-bin.stable.latest.minimal.override {
          targets = [ "wasm32-unknown-unknown" "wasm32-wasip1" ];
        };
        # Native rustc (host target only, no wasm-std) for the §13.5
        # `rust_host` embedder example — a Rust program linking `libzwasm.a`
        # over the C ABI. Kept in its OWN lean shell (`devShells.rust-host`),
        # NOT in `default`, so the test hosts' `zig build test-all` shell stays
        # toolchain-free; only the `run-rust-host` step opts into native rust.
        rustNative = genPkgs.rust-bin.stable.latest.minimal;
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.git           # real git — macOS /usr/bin/git is an xcrun shim that breaks under `nix develop` (run_bench.sh git rev-parse)
            pkgs.hyperfine
            pkgs.yq-go
            pkgs.python3
            pkgs.wabt          # wat2wasm / wast2json — required by Phase 1+ spec runner
            pkgs.wasmtime      # reference runtime — drives the §9.6 / 6.2 differential gate
            pkgs.wazero        # §11.3 SIMD gap comparator (run_bench.sh --compare=wazero); D-074
            pkgs.wasm-tools    # dump / validate / print / strip / smith / shrink — Phase 6+ debug + Phase 7 fuzz corpus (per ADR-0015 candidate)
            pkgs.lldb          # interactive debugger + watchpoints (per ADR-0015 candidate)
            pkgs.nasm          # `ndisasm -b 64 file.bin` for raw JIT byte stream disasm — paired with lldb / objdump for SEGV root-cause work (autonomous loop x86_64 JIT debug per `.claude/rules/debug_jit.md`)
          ]
          # §11.3 wasmer comparator — Mac-only. On x86_64-linux nixpkgs has no
          # binary-cache hit for wasmer, so it builds from source and the
          # Rust/LLVM link fails, breaking the dev shell on the ubuntu/windows
          # TEST hosts (which build this same shell for `zig build test-all`).
          # The SIMD gap analysis (§11.3) runs Mac-only, where wasmer resolves
          # from cache, so confine it there.
          ++ pkgs.lib.optionals (system == "aarch64-darwin") [ pkgs.wasmer ];

          shellHook = ''
            echo "zwasm v2 dev shell"
            zig version
            echo "wasm-tools: $(wasm-tools --version 2>/dev/null || echo 'NOT FOUND')"
            echo "lldb:       $(lldb --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
            echo "dsymutil:   $(which dsymutil 2>/dev/null || echo 'NOT FOUND')"
            # ADR-0064 + commit c89ec713 (2026-05-11): activate the
            # project's git hooks by pointing core.hooksPath at
            # `.githooks/`. The setting lives in `.git/config`
            # (per-clone, not committed); fresh clones — and any
            # local repo where the config drifted back to `.git/hooks`
            # — get the hooks re-activated on `nix develop` entry.
            # Idempotent: only re-sets if the current value differs.
            if git rev-parse --git-dir >/dev/null 2>&1; then
              current_hp=$(git config --local --get core.hooksPath 2>/dev/null || echo "")
              if [ "$current_hp" != ".githooks" ]; then
                git config core.hooksPath .githooks
                echo "git hooks: core.hooksPath set to .githooks (was: $current_hp)"
              fi
            fi
          '';
        };

        # `rust_host` embedder shell (§13.5; ADR-pending toolchain-on-test-host).
        # zig (builds `libzwasm.a`) + native rustc (builds `examples/rust_host/
        # hello.rs` linking it). Used by the `run-rust-host` step on the Linux
        # test host via `nix develop .#rust-host`; kept separate from `default`
        # so `test-all` stays toolchain-free. Windows uses native winget rust
        # (no nix there). Enter with `nix develop .#rust-host`.
        devShells.rust-host = genPkgs.mkShell {
          packages = [
            zig
            rustNative          # native rustc + cargo (host target)
            pkgs.git
          ];
          shellHook = ''
            echo "zwasm v2 — rust_host embedder shell (native rustc; §13.5 3-OS rust run)"
            echo "  rustc: $(rustc --version 2>/dev/null || echo 'NOT FOUND')"
          '';
        };

        # Realworld-fixture GENERATION shell (Mac host only; see
        # `.dev/toolchain_provisioning.md`). Provides the real toolchains
        # that compile C / C++ / Rust / Go to wasm. The emitted `.wasm` is
        # committed as a binary artifact and run on the test hosts by the
        # Zig-built edge-runner — so these heavy toolchains stay OUT of
        # `devShells.default` (the test hosts never need them). Enter with
        # `nix develop .#gen`. Mirrors v1's flake-as-source-of-truth model
        # (v1 `flake.nix` lines 144-187 + `versions.lock`).
        devShells.gen = genPkgs.mkShell {
          packages = [
            zig
            rustWasm                 # rustc + cargo, targets wasm32-unknown-unknown / wasm32-wasip1
            genPkgs.emscripten       # emcc — C/C++ → wasm (incl. -sMEMORY64 memory64 corpus)
            genPkgs.tinygo           # Go subset → wasm / wasip1 (bundles binaryen)
            genPkgs.go               # `GOOS=wasip1 GOARCH=wasm go build`
            genPkgs.llvmPackages.clang # clang --target=wasm32/wasm64 (the clang_musttail / clang_wasm64 path)
            genPkgs.lld              # wasm-ld linker for the bare clang → wasm path
            genPkgs.wasm-tools       # parse / print / validate the emitted modules
            genPkgs.python3
          ];

          # NOTE: keep the shellHook CHEAP — do NOT run `emcc` here. The
          # first `emcc` invocation builds the emscripten sysroot cache
          # (slow, minutes), so calling it on every shell entry would tax
          # rust/clang/go/tinygo generation that never touches emcc. emcc's
          # cache builds lazily on its first real use.
          shellHook = ''
            echo "zwasm v2 — realworld-fixture GENERATION shell (Mac host only)"
            # emscripten needs a writable cache (the nix store path is RO).
            export EM_CACHE="''${EM_CACHE:-$HOME/.cache/emscripten}"
            mkdir -p "$EM_CACHE"
            # nix-wrapped clang injects -fzero-call-used-regs (unsupported for
            # wasm); the realworld build scripts must run with this cleared.
            export NIX_HARDENING_ENABLE=""
            echo "  toolchains: zig rustc(wasm32) emcc tinygo go clang+lld on PATH"
            echo "  EM_CACHE=$EM_CACHE  (emcc builds its cache lazily on first use)"
            echo "Generated .wasm is COMMITTED; test hosts run it via the edge-runner (no toolchain there)."
          '';
        };

        # Multi-runtime BENCHMARK shell (Mac host only; ADR-0163 workstream B).
        # Pins every comparator runtime in one hermetic shell so
        # `scripts/run_bench.sh --compare=all` reproduces against the full set
        # (wasmtime / wazero / wasmer / wasmedge). The `default` shell carries
        # only the §11.3 SIMD-gap trio (wasmtime / wazero / wasmer) — this shell
        # adds the WASI-realworld AOT comparator (wasmedge) on top. Invoked
        # manually on the Mac bench host via `nix develop .#bench`; never built
        # by the ubuntu/windows TEST hosts (which build `default` for
        # `test-all`), so the heavier comparators here can't break their gate.
        #
        # wasm3 is deliberately EXCLUDED: nixpkgs marks wasm3-0.5.0 insecure
        # (8 CVEs incl. CVE-2022-39974; upstream unmaintained since 2021).
        # Pinning a CVE-laden runtime into a public release flake is wrong, and
        # v1's comparator set never included it — so no parity is lost.
        devShells.bench = pkgs.mkShell {
          packages = [
            zig                # builds ./zig-out/bin/zwasm for the comparison
            pkgs.git
            pkgs.hyperfine     # the timing harness run_bench.sh drives
            pkgs.yq-go         # results YAML post-processing
            pkgs.python3       # hyperfine-JSON → ms parsing (run_bench.sh)
            pkgs.wasmtime      # Cranelift JIT reference
            pkgs.wazero        # pure-Go interpreter/compiler comparator
            pkgs.wasmedge      # LLVM AOT comparator (WASI _start)
          ]
          # wasmer is a binary-cache hit on aarch64-darwin but builds from
          # source (Rust/LLVM) elsewhere; the bench host is Mac, so confine it
          # there — same rationale as `default` (flake.nix §default wasmer note).
          ++ pkgs.lib.optionals (system == "aarch64-darwin") [ pkgs.wasmer ];

          shellHook = ''
            echo "zwasm v2 — multi-runtime BENCHMARK shell (Mac host only; ADR-0163)"
            for rt in wasmtime wazero wasmer wasmedge; do
              printf '  %-9s %s\n' "$rt:" "$(command -v "$rt" >/dev/null 2>&1 && "$rt" --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
            done
            echo "Run: nix develop .#bench --command bash scripts/run_bench.sh --compare=all"
          '';
        };
      });
}
