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
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.hyperfine
            pkgs.yq-go
            pkgs.python3
            pkgs.wabt          # wat2wasm / wast2json — required by Phase 1+ spec runner
            pkgs.wasmtime      # reference runtime — drives the §9.6 / 6.2 differential gate
            pkgs.wasm-tools    # dump / validate / print / strip / smith / shrink — Phase 6+ debug + Phase 7 fuzz corpus (per ADR-0015 candidate)
            pkgs.lldb          # interactive debugger + watchpoints (per ADR-0015 candidate)
            pkgs.nasm          # `ndisasm -b 64 file.bin` for raw JIT byte stream disasm — paired with lldb / objdump for SEGV root-cause work (autonomous loop x86_64 JIT debug per `.claude/rules/debug_jit.md`)
          ];

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
      });
}
