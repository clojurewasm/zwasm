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
          ];

          shellHook = ''
            echo "zwasm v2 dev shell"
            zig version
          '';
        };
      });
}
