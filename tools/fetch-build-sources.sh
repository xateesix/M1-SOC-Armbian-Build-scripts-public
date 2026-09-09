#!/usr/bin/env bash
# Install deps, download release tarball, verify v64 build inputs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO/config.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"

ARMBIAN_BUILD="${BUILD_ARMBIAN_PATH:-/home/YOUR_USERNAME/scratch/Projects/rk3308bs-workspace/M1-SOC-Armbian-Build}"
KERNEL_SRC="${KERNEL_SRC_PATH:-$HOME/linux-v6.18}"
REL="$REPO/releases/1.0.0"
FAC_PART="$REPO/factory_fresh/03_partitions"
FAC_BOOT="$REPO/factory_fresh/04_boot_unpacked"
FETCH_KERNEL="${FETCH_KERNEL_SOURCE:-0}"
FETCH_ARMBIAN="${FETCH_ARMBIAN_SOURCE:-0}"

info() { echo ">>> $*"; }
warn() { echo "WARN: $*"; }
ok()   { echo "OK: $*"; }

bash "$SCRIPT_DIR/install-build-deps.sh"

if [[ "$FETCH_ARMBIAN" == "1" ]]; then
  if [[ ! -d "$ARMBIAN_BUILD/.git" ]]; then
    info "Cloning Armbian build framework -> $ARMBIAN_BUILD"
    git clone --depth 1 https://github.com/armbian/build "$ARMBIAN_BUILD"
  else
    ok "Armbian build tree present: $ARMBIAN_BUILD"
  fi
fi

if [[ "$FETCH_KERNEL" == "1" ]]; then
  if [[ ! -d "$KERNEL_SRC/.git" ]]; then
    info "Cloning Linux stable v6.18 -> $KERNEL_SRC"
    git clone --depth 1 --branch v6.18 \
      https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KERNEL_SRC" \
      || git clone --depth 1 --branch linux-6.18.y \
        https://github.com/gregkh/linux.git "$KERNEL_SRC"
  else
    ok "Kernel source present: $KERNEL_SRC"
  fi
fi

mkdir -p "$REL" "$FAC_PART" "$FAC_BOOT"

if [[ -n "${BUILD_ARTIFACTS_URL:-}" ]]; then
  STAMP="$REPO/.artifacts-fetched"
  if [[ ! -f "$STAMP" ]]; then
    info "Downloading build artifacts from BUILD_ARTIFACTS_URL"
    TMP="$(mktemp -d)"
    curl -fsSL "$BUILD_ARTIFACTS_URL" -o "$TMP/artifacts.tar.gz"
    tar -xzf "$TMP/artifacts.tar.gz" -C "$REPO"
    rm -rf "$TMP"
    touch "$STAMP"
  else
    ok "Build artifacts already fetched ($STAMP)"
  fi
elif [[ ! -f "$REL/_Image-v22" || ! -f "$REL/rootfs-v61.img" ]]; then
  warn "Set BUILD_ARTIFACTS_URL in config.env to the GitHub Releases tarball URL"
fi

PT="$REPO/partition_templates"
if [[ -d "$PT/03_partitions" ]]; then
  if [[ ! -f "$FAC_PART/MiniLoaderAll.bin" ]]; then
    info "Installing partition templates from release tarball"
    cp -a "$PT/03_partitions"/. "$FAC_PART/"
  fi
  if [[ -f "$PT/04_boot_unpacked/resource.img" && ! -f "$FAC_BOOT/resource.img" ]]; then
    cp "$PT/04_boot_unpacked/resource.img" "$FAC_BOOT/resource.img"
  fi
fi

if [[ -n "${FACTORY_FIRMWARE_DIR:-}" && -d "$FACTORY_FIRMWARE_DIR" ]]; then
  if [[ ! -f "$FAC_PART/MiniLoaderAll.bin" ]]; then
    info "Copying partition templates from FACTORY_FIRMWARE_DIR"
    cp -a "$FACTORY_FIRMWARE_DIR"/. "$FAC_PART/"
  fi
fi

missing=0
check_file() {
  local f="$1" hint="$2"
  if [[ -f "$f" ]]; then ok "$f"; else warn "Missing: $f - $hint"; missing=1; fi
}

echo ""
echo "=== Verifying eMMC build inputs (build-release-v64.sh) ==="
check_file "$REL/_Image-v22" "in build-artifacts tarball"
check_file "$REL/rootfs-v61.img" "in build-artifacts tarball"
check_file "$REL/_uboot-memlayout.img" "in build-artifacts tarball"
check_file "$FAC_BOOT/resource.img" "in partition_templates/"
check_file "$FAC_PART/MiniLoaderAll.bin" "in partition_templates/"
if [[ -f "$REL/_modules_6.18.0-dirty/kernel/drivers/leds/leds-pwm.ko" ]]; then
  ok "leds-pwm.ko module"
else
  warn "Missing leds-pwm.ko - in build-artifacts tarball"
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  echo ""
  fail_msg="Required build inputs missing."
  echo "ERROR: $fail_msg"
  echo "  1) Set BUILD_ARTIFACTS_URL in config.env"
  echo "  2) Re-run: bash tools/fetch-build-sources.sh"
  exit 1
fi

echo ""
echo "All required build inputs present."