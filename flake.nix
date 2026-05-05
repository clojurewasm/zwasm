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

        # Zig 0.16.0 binary (per-architecture URLs and hashes)
        zigArchInfo = {
          "aarch64-darwin" = {
            url = "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz";
            sha256 = "0yqiq1nrjfawh1k24mf969q1w9bhwfbwqi2x8f9zklca7bsyza26";
          };
          "x86_64-darwin" = {
            url = "https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz";
            sha256 = "0dibmghlqrr8qi5cqs9n0nl25qdnb5jvr542dyljfqdyy2bzzh2x";
          };
          "x86_64-linux" = {
            url = "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz";
            sha256 = "1kgamnyy7vsw5alb5r4xk8nmgvmgbmxkza5hs7b51x6dbgags1h6";
          };
          "aarch64-linux" = {
            url = "https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz";
            sha256 = "12gf4d1rjncc8r4i32sfdmnwdl0d6hg717hb3801zxjlmzmpsns0";
          };
        }.${system} or (throw "Unsupported system: ${system}");

        zigSrc = builtins.fetchTarball {
          url = zigArchInfo.url;
          sha256 = zigArchInfo.sha256;
        };

        zigBin = pkgs.runCommand "zig-0.16.0-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

        # wasi-sdk 30 binary (for C/C++ → wasm32-wasi compilation)
        wasiSdkArchInfo = {
          "aarch64-darwin" = {
            url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-arm64-macos.tar.gz";
            sha256 = "0f2zqwxzdf6fjzjjcycvrk1mjg2w29lk19lpjc7sddnxwgdrzf5l";
          };
          "x86_64-linux" = {
            url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-x86_64-linux.tar.gz";
            sha256 = "145cf587396n01zgf43hzdpdmivh3sr4fx9sfs8g5p0fw45clys1";
          };
          "x86_64-darwin" = {
            url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-x86_64-macos.tar.gz";
            sha256 = ""; # untested
          };
          "aarch64-linux" = {
            url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-arm64-linux.tar.gz";
            sha256 = ""; # untested
          };
        }.${system} or null;

        wasiSdkSrc = if wasiSdkArchInfo != null then
          builtins.fetchTarball {
            url = wasiSdkArchInfo.url;
            sha256 = wasiSdkArchInfo.sha256;
          }
        else null;

        wasiSdkBin = if wasiSdkSrc != null then
          pkgs.runCommand "wasi-sdk-30-wrapper" {} ''
            mkdir -p $out/bin $out/share
            ln -s ${wasiSdkSrc}/bin/* $out/bin/
            ln -s ${wasiSdkSrc}/share/wasi-sysroot $out/share/wasi-sysroot
            ln -s ${wasiSdkSrc}/lib $out/lib
          ''
        else null;

        # wasm-tools 1.248.0 (per-architecture URLs and hashes; mirrors versions.lock).
        wasmToolsArchInfo = {
          "aarch64-darwin" = {
            url = "https://github.com/bytecodealliance/wasm-tools/releases/download/v1.248.0/wasm-tools-1.248.0-aarch64-macos.tar.gz";
            sha256 = "1qca0yf2g6r7plkdhxl6k7wkv4dksy0wn73aq3w9icd0zqn8cq8i";
          };
          "x86_64-darwin" = {
            url = "https://github.com/bytecodealliance/wasm-tools/releases/download/v1.248.0/wasm-tools-1.248.0-x86_64-macos.tar.gz";
            sha256 = "175fwsg2zwn11zy9r5rjmkn10crwqz22iqdfn870agaj1hx3ifdh";
          };
          "x86_64-linux" = {
            url = "https://github.com/bytecodealliance/wasm-tools/releases/download/v1.248.0/wasm-tools-1.248.0-x86_64-linux.tar.gz";
            sha256 = "001ffxxl8nnhbp42ry5c9grb1f004qlxf700n3ibyp94wpbn25a3";
          };
          "aarch64-linux" = {
            url = "https://github.com/bytecodealliance/wasm-tools/releases/download/v1.248.0/wasm-tools-1.248.0-aarch64-linux.tar.gz";
            sha256 = "0l391n4qjnr8prrf1linl3ba1xsl4hj8paf2d4170sv0kg0nia92";
          };
        }.${system} or (throw "Unsupported system for wasm-tools: ${system}");

        wasmToolsSrc = builtins.fetchTarball {
          url = wasmToolsArchInfo.url;
          sha256 = wasmToolsArchInfo.sha256;
        };

        wasmToolsBin = pkgs.runCommand "wasm-tools-1.248.0-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${wasmToolsSrc}/wasm-tools $out/bin/wasm-tools
        '';

        # wasmtime 42.0.1 (per-architecture URLs and hashes; mirrors versions.lock).
        wasmTimeArchInfo = {
          "aarch64-darwin" = {
            url = "https://github.com/bytecodealliance/wasmtime/releases/download/v42.0.1/wasmtime-v42.0.1-aarch64-macos.tar.xz";
            sha256 = "13yyvmnyzzzwf3gkb0in9w67s7jybb69bdma71xpnm5ch3v9wrsb";
          };
          "x86_64-darwin" = {
            url = "https://github.com/bytecodealliance/wasmtime/releases/download/v42.0.1/wasmtime-v42.0.1-x86_64-macos.tar.xz";
            sha256 = "1qvksa3k8vv4q2xmvviqmd50qk9s1ydc5ssz17jyi3f5v4h4zksd";
          };
          "x86_64-linux" = {
            url = "https://github.com/bytecodealliance/wasmtime/releases/download/v42.0.1/wasmtime-v42.0.1-x86_64-linux.tar.xz";
            sha256 = "0k76lip8iqrcnc4jbv706kqgxd35f4034qysdvwm1nzbpbxpzxw2";
          };
          "aarch64-linux" = {
            url = "https://github.com/bytecodealliance/wasmtime/releases/download/v42.0.1/wasmtime-v42.0.1-aarch64-linux.tar.xz";
            sha256 = "02r0lmqrzi0xszkn8pnfix0g9wk4il82b1xgwypwhmkj6n7x0l0j";
          };
        }.${system} or (throw "Unsupported system for wasmtime: ${system}");

        wasmTimeSrc = builtins.fetchTarball {
          url = wasmTimeArchInfo.url;
          sha256 = wasmTimeArchInfo.sha256;
        };

        wasmTimeBin = pkgs.runCommand "wasmtime-42.0.1-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${wasmTimeSrc}/wasmtime $out/bin/wasmtime
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "zwasm";

          buildInputs = with pkgs; [
            # Compiler
            zigBin

            # Wasm runtimes (benchmark comparison targets) — pinned at versions.lock WASMTIME_VERSION
            wasmTimeBin

            # JS/Wasm runtimes
            bun
            nodejs

            # Data processing
            yq-go
            jq

            # Benchmarking — hyperfine has no aarch64-darwin prebuilt asset
            # upstream, so we keep the nixpkgs derivation here. Pinning is
            # tracked separately; not blocking for spec/realworld.
            hyperfine

            # Wasm build tools
            tinygo
            wasmToolsBin  # json-from-wast (spec test conversion), component inspection — pinned at versions.lock WASM_TOOLS_VERSION

            # Real-world wasm compilation toolchains
            go          # GOOS=wasip1 GOARCH=wasm (Go 1.21+)
            # Rust: use system rustup (rustup target add wasm32-wasip1)
            # wasi-sdk: provided via custom fetch below

            # Utilities
            gnused
            coreutils
            python3
          ] ++ pkgs.lib.optionals (wasiSdkBin != null) [ wasiSdkBin ];

          shellHook = ''
            ${if wasiSdkSrc != null then ''
              export WASI_SDK_PATH="${wasiSdkSrc}"
            '' else ""}
          '';
        };
      }
    );
}
