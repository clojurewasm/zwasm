{
  description = "zwasm v2 — a from-scratch WebAssembly runtime in Zig 0.16.0";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
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
      });
}
