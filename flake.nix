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
          ];

          shellHook = ''
            echo "zwasm v2 dev shell"
            zig version
          '';
        };
      });
}
