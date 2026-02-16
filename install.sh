#!/usr/bin/env bash
# Install zwasm binary.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --prefix=/usr/local
#
# Options:
#   --prefix=DIR    Install directory (default: ~/.local)
#   --version=TAG   Specific version (default: latest)

set -euo pipefail

PREFIX="${HOME}/.local"
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --prefix=*) PREFIX="${arg#*=}" ;;
        --version=*) VERSION="${arg#*=}" ;;
    esac
done

REPO="clojurewasm/zwasm"
BIN_DIR="${PREFIX}/bin"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "${OS}" in
    darwin) PLATFORM="macos" ;;
    linux)  PLATFORM="linux" ;;
    *)      echo "Error: Unsupported OS: ${OS}"; exit 1 ;;
esac

case "${ARCH}" in
    x86_64|amd64)   ARCH_NAME="x86_64" ;;
    arm64|aarch64)   ARCH_NAME="aarch64" ;;
    *)               echo "Error: Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

ARTIFACT="zwasm-${PLATFORM}-${ARCH_NAME}"

# Get latest version if not specified
if [ -z "$VERSION" ]; then
    VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    if [ -z "$VERSION" ]; then
        echo "Error: Could not determine latest version"
        exit 1
    fi
fi

echo "Installing zwasm ${VERSION} (${PLATFORM}/${ARCH_NAME})..."

URL="https://github.com/${REPO}/releases/download/${VERSION}/${ARTIFACT}.tar.gz"
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

curl -fsSL "${URL}" -o "${TMPDIR}/${ARTIFACT}.tar.gz"
tar xzf "${TMPDIR}/${ARTIFACT}.tar.gz" -C "${TMPDIR}"

mkdir -p "${BIN_DIR}"
mv "${TMPDIR}/zwasm" "${BIN_DIR}/zwasm"
chmod +x "${BIN_DIR}/zwasm"

echo "Installed: ${BIN_DIR}/zwasm"

# Check if in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
    echo ""
    echo "Add to your PATH:"
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
fi
