#!/usr/bin/env bash
#
# Install build dependencies on Debian/Ubuntu (including WSL2 Ubuntu).
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    SUDO=sudo
else
    SUDO=
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script only supports Debian/Ubuntu. Install these packages manually:"
    echo "  git make curl patch zip unzip python3 bc bison flex cpio perl rsync"
    echo "  clang lld llvm libssl-dev libelf-dev libncurses-dev"
    echo "  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu"
    echo "  device-tree-compiler dwarves zstd lz4 xz-utils kmod"
    exit 1
fi

$SUDO apt-get update

PACKAGES=(
    build-essential git curl ca-certificates
    make patch zip unzip xz-utils zstd lz4
    python3 python3-pip python-is-python3
    bc bison flex cpio perl rsync kmod
    libssl-dev libelf-dev libncurses-dev openssl
    device-tree-compiler dwarves
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
)

# Prefer clang 12 (LineageOS builds this kernel with clang-r416183b == clang 12).
# Fall back to other versions if the distro no longer ships clang-12.
CLANG_PKGS=()
if apt-cache show clang-12 >/dev/null 2>&1; then
    CLANG_PKGS=(clang-12 lld-12 llvm-12)
elif apt-cache show clang-14 >/dev/null 2>&1; then
    CLANG_PKGS=(clang-14 lld-14 llvm-14)
elif apt-cache show clang >/dev/null 2>&1; then
    CLANG_PKGS=(clang lld llvm)
else
    echo "No clang package found" >&2
    exit 1
fi

$SUDO apt-get install -y --no-install-recommends "${PACKAGES[@]}" "${CLANG_PKGS[@]}"

echo
echo "Done. Installed toolchain:"
( clang-12 --version || clang-14 --version || clang --version ) 2>/dev/null | head -n1
