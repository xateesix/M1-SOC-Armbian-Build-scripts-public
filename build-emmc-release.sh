#!/usr/bin/env bash
# End-to-end: Armbian .img -> versioned monolithic RK3308 eMMC update.img
#
# Run in WSL/Ubuntu (pack step needs loop mounts).
# Final flash file is built on Windows via AFPTool + RKImageMaker.
#
# Usage:
#   ./build-emmc-release.sh --armbian ./Armbian-*.img --version 1.0.0
#
# Options:
#   --armbian PATH     built Armbian image (required)
#   --version VER      release version string (required)
#   --factory DIR      bootloader blobs (default: factory_fresh/03_partitions)
#   --shrink           shrink rootfs before pack (recommended)
#   --skip-modules     Phase A only: extract/inject factory 8189fs.ko
#   --factory-kernel   Phase A boot (factory boot.img + factory WiFi module)
#   --pack-only        skip windows pack (staging only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="${PACK_ROOT:-/home/YOUR_USERNAME/scratch/Projects/pack}"
ARMBIAN_IMG=""
VERSION=""
FACTORY_DIR="$SCRIPT_DIR/factory_fresh/03_partitions"
SHRINK=1
SKIP_MODULES=1
BOOT_MODE="armbian"
PACK_ONLY=0

usage() {
    sed -n '1,16p' "$0"
    echo ""
    echo "Example:"
    echo "  ./build-emmc-release.sh --armbian output/Armbian-*.img --version 1.0.0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --armbian) ARMBIAN_IMG="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --factory) FACTORY_DIR="$2"; shift 2 ;;
        --shrink) SHRINK=1; shift ;;
        --no-shrink) SHRINK=0; shift ;;
        --skip-modules) SKIP_MODULES=1; shift ;;
        --factory-kernel) BOOT_MODE="factory"; SKIP_MODULES=0; shift ;;
        --pack-only) PACK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown: $1"; usage; exit 1 ;;
    esac
done

[[ -n "$ARMBIAN_IMG" && -n "$VERSION" ]] || { usage; exit 1; }
[[ -f "$ARMBIAN_IMG" ]] || { echo "Missing: $ARMBIAN_IMG"; exit 1; }

if ! sudo -n true 2>/dev/null; then
    echo "ERROR: This script needs WSL sudo (loop mounts). Run in an interactive WSL shell:"
    echo "  sudo -v"
    echo "  $0 --armbian \"$ARMBIAN_IMG\" --version \"$VERSION\""
    exit 1
fi

OUT_DIR="$PACK_ROOT/releases/$VERSION"
PACK_INPUT="$OUT_DIR/pack_input"
OUTPUT_IMG="rk3308bs-${VERSION}-emmc.img"

echo "=== RK3308BS eMMC release $VERSION ==="
echo "Armbian: $ARMBIAN_IMG"
echo "Factory: $FACTORY_DIR"
echo "Out:     $OUT_DIR"
echo "Boot:    Phase ${BOOT_MODE} (armbian = custom kernel boot.img)"
echo ""

if [[ "$SKIP_MODULES" != "1" ]]; then
    KV="$SCRIPT_DIR/bsp/modules-factory/KERNEL_VERSION"
    if [[ ! -f "$KV" ]] || ! grep -qE '^[0-9]+\.[0-9]+' "$KV" 2>/dev/null; then
        echo "=== Extract WiFi modules from factory rootfs (one-time per factory dump) ==="
        rm -rf "$SCRIPT_DIR/bsp/modules-factory/"*
        bash "$SCRIPT_DIR/tools/extract-factory-modules.sh"
    fi
fi

PACK_ARGS=(
    --armbian "$ARMBIAN_IMG"
    --factory "$FACTORY_DIR"
    --out "$OUT_DIR"
    --version "$VERSION"
)
[[ "$SHRINK" == "1" ]] && PACK_ARGS+=(--shrink)
[[ "$SKIP_MODULES" != "1" ]] && PACK_ARGS+=(--modules "$SCRIPT_DIR/bsp/modules-factory")

bash "$SCRIPT_DIR/pack-armbian-for-emmc.sh" "${PACK_ARGS[@]}" --boot-mode "$BOOT_MODE"

# Staging only. Monolithic packaging is handled by the Linux-only
# tools/pack-firmware-linux.sh step in the from-source build flow.
echo "Staging complete. Monolithic packaging runs via tools/pack-firmware-linux.sh."
exit 0
