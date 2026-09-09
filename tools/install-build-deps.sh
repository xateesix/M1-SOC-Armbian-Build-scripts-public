#!/usr/bin/env bash
# Install host packages required to compile and pack RK3308BS eMMC images.
set -euo pipefail
INSTALL_DEPS="${INSTALL_DEPS:-1}"
if [[ "$INSTALL_DEPS" != "1" ]]; then
  echo "Skipping apt install (INSTALL_DEPS=0)"
else
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found. Run this script in WSL or Debian/Ubuntu."
    exit 1
  fi
  echo "=== Installing build dependencies (apt) ==="
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl wget ca-certificates \
    python3 python3-pil python3-pip \
    device-tree-compiler u-boot-tools \
    lz4 e2fsprogs file bc bison flex \
    libssl-dev libncurses-dev \
    gcc-aarch64-linux-gnu \
    rsync openssh-client \
    debugfs 2>/dev/null || \
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl wget ca-certificates \
    python3 python3-pil python3-pip \
    device-tree-compiler u-boot-tools \
    lz4 e2fsprogs file bc bison flex \
    libssl-dev libncurses-dev \
    gcc-aarch64-linux-gnu \
    rsync openssh-client
fi

need() { command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }
for c in git python3 dtc lz4 fdtput debugfs; do need "$c"; done
echo "Build dependencies OK"
