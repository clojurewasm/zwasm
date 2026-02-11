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

        # Zig 0.15.2 binary (per-architecture URLs and hashes)
        zigArchInfo = {
          "aarch64-darwin" = {
            url = "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz";
            sha256 = "1csy5ch8aym67w06ffmlwamrzkfq8zwv4kcl6bcpc5vn1cbhd31g";
          };
          "x86_64-darwin" = {
            url = "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz";
            sha256 = ""; # untested
          };
          "x86_64-linux" = {
            url = "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz";
            sha256 = "0skmy2qjg2z4bsxnkdzqp1hjzwwgnvqhw4qjfnsdpv6qm23p4wm0";
          };
          "aarch64-linux" = {
            url = "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz";
            sha256 = ""; # untested
          };
        }.${system} or (throw "Unsupported system: ${system}");

        zigSrc = builtins.fetchTarball {
          url = zigArchInfo.url;
          sha256 = zigArchInfo.sha256;
        };

        zigBin = pkgs.runCommand "zig-0.15.2-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

        # Wasmer 7.0.1 prebuilt binary (nixpkgs 5.0.4 has __rust_probestack link error on x86_64)
        wasmerArchInfo = {
          "aarch64-darwin" = {
            url = "https://github.com/wasmerio/wasmer/releases/download/v7.0.1/wasmer-darwin-arm64.tar.gz";
            sha256 = "1knawb09j00wx5n6fzcd4ya9zdfzyf9gzmr9zqb9787afcj8minh";
          };
          "x86_64-darwin" = {
            url = "https://github.com/wasmerio/wasmer/releases/download/v7.0.1/wasmer-darwin-amd64.tar.gz";
            sha256 = "1d0r8991vvhw4f364bk94li95pywvp31zm1gan7xd7659g39cwbd";
          };
          "x86_64-linux" = {
            url = "https://github.com/wasmerio/wasmer/releases/download/v7.0.1/wasmer-linux-amd64.tar.gz";
            sha256 = "0pz1q2s3c0l9c6gsfyaki511dwdiw1yc0s7jvv244mjrw0qagz8h";
          };
          "aarch64-linux" = {
            url = "https://github.com/wasmerio/wasmer/releases/download/v7.0.1/wasmer-linux-aarch64.tar.gz";
            sha256 = "0653fpsh94y936wps7g6m1f1v8rfm145hc6rlfij6zvhxj06xxlh";
          };
        }.${system} or (throw "Unsupported system for wasmer: ${system}");

        wasmerSrc = builtins.fetchTarball {
          url = wasmerArchInfo.url;
          sha256 = wasmerArchInfo.sha256;
        };

        wasmerBin = pkgs.runCommand "wasmer-7.0.1-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${wasmerSrc}/bin/wasmer $out/bin/wasmer
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "zwasm";

          buildInputs = with pkgs; [
            # Compiler
            zigBin

            # Wasm runtimes (benchmark comparison targets)
            wasmtime

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
            wabt  # wast2json, wat2wasm, wasm2wat (spec test conversion)

            # Utilities
            gnused
            coreutils
            python3
            wasmerBin
          ];

          shellHook = '''';  # silent — avoid noise in SSH/direnv
        };
      }
    );
}
