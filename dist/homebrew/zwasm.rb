# Homebrew formula for zwasm.
#
# To use:
#   1. Create a tap repo: github.com/clojurewasm/homebrew-tap
#   2. Copy this file to Formula/zwasm.rb in that repo
#   3. Update version, URLs, and SHA256 hashes on each release
#   4. Users install with: brew install clojurewasm/tap/zwasm

class Zwasm < Formula
  desc "Small, fast WebAssembly runtime written in Zig"
  homepage "https://github.com/clojurewasm/zwasm"
  version "1.0.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/clojurewasm/zwasm/releases/download/v#{version}/zwasm-macos-aarch64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_intel do
      # Not yet supported
      odie "zwasm does not support macOS x86_64"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/clojurewasm/zwasm/releases/download/v#{version}/zwasm-linux-aarch64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_intel do
      url "https://github.com/clojurewasm/zwasm/releases/download/v#{version}/zwasm-linux-x86_64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  def install
    bin.install "zwasm"
  end

  test do
    assert_match "zwasm", shell_output("#{bin}/zwasm version")
  end
end
