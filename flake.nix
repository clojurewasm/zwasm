{
  description = "zwasm - Zig WebAssembly runtime (library + CLI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Zig 0.15.2 binary
        zigSrc = builtins.fetchTarball {
          url =
            if system == "aarch64-darwin" then
              "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
            else if system == "x86_64-darwin" then
              "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz"
            else if system == "x86_64-linux" then
              "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz"
            else if system == "aarch64-linux" then
              "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz"
            else throw "Unsupported system: ${system}";
          sha256 = "1csy5ch8aym67w06ffmlwamrzkfq8zwv4kcl6bcpc5vn1cbhd31g";
        };

        zigBin = pkgs.runCommand "zig-0.15.2-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "zwasm";

          buildInputs = with pkgs; [
            # Compiler
            zigBin

            # Wasm runtimes (benchmark comparison targets)
            wasmtime
            wasmer

            # JS/Wasm runtimes
            bun
            nodejs

            # Data processing
            yq-go
            jq

            # Benchmarking
            hyperfine

            # Wasm build tools
            tinygo

            # Utilities
            gnused
            coreutils
            python3
          ];

          shellHook = ''
            echo "zwasm dev environment"
            echo "  Zig:      $(zig version 2>/dev/null || echo 'loading...')"
            echo "  wasmtime: $(wasmtime --version 2>/dev/null || echo 'N/A')"
            echo "  wasmer:   $(wasmer --version 2>/dev/null || echo 'N/A')"
            echo "  Bun:      $(bun --version 2>/dev/null || echo 'N/A')"
            echo "  Node.js:  $(node --version 2>/dev/null || echo 'N/A')"
          '';
        };
      }
    );
}
