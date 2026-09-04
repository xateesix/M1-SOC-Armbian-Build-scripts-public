#!/usr/bin/env bash
# Pull out-of-tree kernel modules from factory rootfs.img into bsp/modules/
# for injection into our custom rootfs (matches factory 5.10.160 boot.img kernel).
#
# Usage:
#   ./tools/extract-factory-modules.sh [factory_rootfs.img] [output_dir]
#
# Default input: factory_fresh/03_partitions/rootfs.img
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOTFS="${1:-$REPO/factory_fresh/03_partitions/rootfs.img}"
OUT="${2:-$REPO/bsp/modules-factory}"

[[ -f "$ROOTFS" ]] || { echo "Missing factory rootfs: $ROOTFS"; exit 1; }
need() { command -v "$1" >/dev/null || { echo "Need: $1"; exit 1; }; }
need python3

WORKDIR="$(mktemp -d)"
cleanup() { sudo umount "$WORKDIR/mnt" 2>/dev/null || true; rm -rf "$WORKDIR"; }
trap cleanup EXIT

mkdir -p "$WORKDIR/mnt" "$OUT"

echo "Mounting factory rootfs ..."
if ! sudo mount -o loop,ro "$ROOTFS" "$WORKDIR/mnt" 2>/dev/null; then
    OFFSET=$(python3 - "$ROOTFS" <<'PY'
import struct, sys
path = sys.argv[1]
with open(path, "rb") as f:
    f.seek(1024 + 0x38)
    start = struct.unpack("<Q", f.read(8))[0]
print(start)
PY
)
    sudo mount -o loop,ro,offset="$OFFSET" "$ROOTFS" "$WORKDIR/mnt"
fi

MODROOT="$WORKDIR/mnt/lib/modules"
KVER=""
for d in "$MODROOT"/[0-9]*; do
    [[ -d "$d" ]] || continue
    KVER="$(basename "$d")"
    break
done
if [[ -z "$KVER" ]]; then
    found="$(find "$MODROOT" -name '8189fs.ko' 2>/dev/null | head -1 || true)"
    if [[ -n "$found" ]]; then
        KVER="$(basename "$(dirname "$found")")"
        [[ "$KVER" == "extra" ]] && KVER="$(basename "$(dirname "$(dirname "$found")")")"
    fi
fi
[[ -n "$KVER" ]] || KVER="5.10.160"
[[ -d "$MODROOT/$KVER" ]] || { echo "No kernel module tree under $MODROOT/$KVER"; exit 1; }

echo "Factory kernel modules tree: $KVER"
rm -rf "$OUT"
mkdir -p "$OUT/$KVER/extra"

for name in 8189fs; do
    found="$(find "$MODROOT" -name "${name}.ko" 2>/dev/null | head -1 || true)"
    if [[ -n "$found" ]]; then
        cp "$found" "$OUT/$KVER/extra/"
        echo "  copied $(basename "$found")"
    else
        echo "  WARN: ${name}.ko not found under $MODROOT"
    fi
done

cp -a "$MODROOT/$KVER/modules.dep" "$MODROOT/$KVER/modules.dep.bin" \
    "$MODROOT/$KVER/modules.alias" "$MODROOT/$KVER/modules.alias.bin" \
    "$MODROOT/$KVER/modules.softdep" "$MODROOT/$KVER/modules.symbols" \
    "$MODROOT/$KVER/modules.symbols.bin" \
    "$OUT/$KVER/" 2>/dev/null || true

echo "$KVER" >"$OUT/KERNEL_VERSION"
echo "Saved to $OUT (kernel $KVER)"
