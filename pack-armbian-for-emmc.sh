#!/usr/bin/env bash
# Pack custom Armbian rootfs into a Rockchip monolithic eMMC update image.
#
# Uses factory bootloader stack (MiniLoader, parameter, uboot, trust) and
# factory-format boot.img (LZ4 kernel patched cmdline only -- interim).
# Rootfs is YOUR Armbian build, not factory rootfs.img.
#
# Usage:
#   ./pack-armbian-for-emmc.sh \
#     --armbian ./Armbian-rk3308bs-*.img \
#     --factory ./factory_fresh/03_partitions \
#     --out ./releases/build-001
#
# Options:
#   --version 1.0.0          stamp /etc/rk3308bs-release in rootfs
#   --console ttyS3,1500000n8   serial console (Phase B default)
#   --boot-mode armbian|factory  boot.img source (default: armbian)
#   --modules ./bsp/modules-factory   Phase A only: inject factory 8189fs.ko
#   --shrink                 min-size ext4 before pack (faster RKDevTool flash)
#
# Then (Windows):
#   .\windows-pack-update.ps1 -PackInput releases\build-001\pack_input `
#       -Output rk3308bs-1.0.0-emmc.img
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="${PACK_ROOT:-/home/YOUR_USERNAME/scratch/Projects/pack}"
ARMBIAN_IMG=""
FACTORY_DIR=""
OUT_DIR=""
ROOT_PART="${ROOT_PART:-6}"
EMMC_ROOT_PART="$ROOT_PART"
BOOT_MODE="${BOOT_MODE:-armbian}"
CONSOLE="${CONSOLE:-ttyS3,1500000n8}"
VERSION="${VERSION:-dev}"
[[ -z "$OUT_DIR" ]] && OUT_DIR="$PACK_ROOT/releases/$VERSION"
MODULES_DIR="${MODULES_DIR:-$SCRIPT_DIR/bsp/modules-factory}"
SHRINK="${SHRINK:-0}"
PATCH_BOOT="${PATCH_BOOT:-$SCRIPT_DIR/factory_fresh/tools/patch-bootimg-cmdline.sh}"
PATCH_UBOOT_MEMLAYOUT="${PATCH_UBOOT_MEMLAYOUT:-$SCRIPT_DIR/tools/patch-uboot-memlayout.py}"

usage() {
    sed -n '1,22p' "$0"
    echo ""
    echo "Required: --armbian --factory --out"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --armbian) ARMBIAN_IMG="$2"; shift 2 ;;
        --factory) FACTORY_DIR="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --root-part) ROOT_PART="$2"; shift 2 ;;
        --console) CONSOLE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --modules) MODULES_DIR="$2"; shift 2 ;;
        --shrink) SHRINK=1; shift ;;
        --boot-mode) BOOT_MODE="$2"; shift 2 ;;
        --factory-kernel) BOOT_MODE="factory"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown: $1"; usage; exit 1 ;;
    esac
done

EMMC_ROOT_PART="$ROOT_PART"

[[ -n "$ARMBIAN_IMG" && -n "$FACTORY_DIR" && -n "$OUT_DIR" ]] || { usage; exit 1; }
[[ -f "$ARMBIAN_IMG" ]] || { echo "Missing Armbian image: $ARMBIAN_IMG"; exit 1; }
if [[ "$BOOT_MODE" == "factory" ]]; then
    [[ -f "$FACTORY_DIR/boot.img" ]] || { echo "Missing $FACTORY_DIR/boot.img"; exit 1; }
fi
[[ -f "$PATCH_BOOT" ]] || { echo "Missing $PATCH_BOOT"; exit 1; }
if [[ "$BOOT_MODE" == "armbian" && ! -f "$PATCH_UBOOT_MEMLAYOUT" ]]; then
    echo "Missing $PATCH_UBOOT_MEMLAYOUT"
    exit 1
fi

ROOT_UUID=""
if [[ -f "$FACTORY_DIR/parameter.txt" ]]; then
    ROOT_UUID=$(grep -E '^uuid:rootfs=' "$FACTORY_DIR/parameter.txt" | cut -d= -f2- || true)
fi

WORKDIR=$(mktemp -d)
MNT="$WORKDIR/mnt"
PACK="$OUT_DIR/pack_input"
IMAGE="$PACK/Image"
cleanup() {
    sudo umount "$MNT" 2>/dev/null || true
    [[ -n "${LOOP:-}" ]] && sudo losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

mkdir -p "$MNT" "$IMAGE" "$OUT_DIR"
LOOP=$(sudo losetup -f --show -P "$ARMBIAN_IMG")
sudo partprobe "$LOOP" 2>/dev/null || sleep 1

ROOT_DEV=""
for p in 1 2 6 "$EMMC_ROOT_PART"; do
    if [[ -b "${LOOP}p${p}" ]]; then
        ROOT_DEV="${LOOP}p${p}"
        break
    fi
done
if [[ -z "$ROOT_DEV" ]] && command -v lsblk >/dev/null; then
    ROOT_DEV=$(lsblk -ln -o NAME,FSTYPE "$LOOP" 2>/dev/null | awk '$2 ~ /ext4|Linux/ {print "/dev/"$1; exit}')
fi
if [[ -z "$ROOT_DEV" || ! -b "$ROOT_DEV" ]]; then
    PART_START=$(fdisk -l "$ARMBIAN_IMG" 2>/dev/null | awk '/Linux root|Linux filesystem/ {print $2; exit}')
    if [[ -n "$PART_START" && "$PART_START" -gt 0 ]]; then
        sudo losetup -d "$LOOP" 2>/dev/null || true
        LOOP=$(sudo losetup -f --show -o "$((PART_START * 512))" "$ARMBIAN_IMG")
        ROOT_DEV="$LOOP"
    fi
fi
[[ -n "$ROOT_DEV" && -b "$ROOT_DEV" ]] || { echo "No root partition on $ARMBIAN_IMG (tried p1/p2/p6 and fdisk offset)"; exit 1; }
echo "Using Armbian root source: $ROOT_DEV (eMMC cmdline still uses mmcblk0p${EMMC_ROOT_PART})" 

ROOTFS_IMG="$OUT_DIR/rootfs.img"
echo "=== Extract custom rootfs from Armbian image ==="
sudo dd if="$ROOT_DEV" of="$ROOTFS_IMG" bs=4M status=progress conv=sparse

if [[ -n "$ROOT_UUID" ]]; then
    command -v tune2fs >/dev/null || { echo "Install e2fsprogs"; exit 1; }
    sudo e2fsck -f -y "$ROOTFS_IMG"
    echo "Setting rootfs PARTUUID: $ROOT_UUID"
    sudo tune2fs -U "$ROOT_UUID" "$ROOTFS_IMG"
fi

echo "=== Customize rootfs (version, hardware modules) ==="
sudo mount -o loop "$ROOTFS_IMG" "$MNT"

install_board_runtime_scripts() {
    local overlay_sbin="$SCRIPT_DIR/overlay/usr/local/sbin"
    local overlay_bin="$SCRIPT_DIR/overlay/usr/local/bin"
    local overlay_systemd="$SCRIPT_DIR/overlay/etc/systemd/system"
    local overlay_motd="$SCRIPT_DIR/overlay/etc/update-motd.d"

    sudo mkdir -p "$MNT/usr/local/sbin" "$MNT/usr/local/bin" "$MNT/etc/systemd/system" "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/etc/update-motd.d"

    for script in rk3308bs-validation.sh rk3308bs-diagnose.sh rk3308bs-load-display.sh rk3308bs-load-wifi.sh rk3308bs-grow-rootfs.sh; do
        if [[ -f "$overlay_sbin/$script" ]]; then
            sudo install -m 0755 "$overlay_sbin/$script" "$MNT/usr/local/sbin/$script"
        fi
    done

    # Installed without the .sh suffix so the MOTD hint's "run: rk3308bs-setup-companion-stack"
    # matches an actual command name the user can type.
    if [[ -f "$overlay_sbin/rk3308bs-setup-companion-stack.sh" ]]; then
        sudo install -m 0755 "$overlay_sbin/rk3308bs-setup-companion-stack.sh" "$MNT/usr/local/sbin/rk3308bs-setup-companion-stack"
    fi

    if [[ -f "$overlay_bin/restore-thermal-trip.sh" ]]; then
        sudo install -m 0755 "$overlay_bin/restore-thermal-trip.sh" "$MNT/usr/local/bin/restore-thermal-trip.sh"
    fi

    for unit in rk3308bs-wifi-modules.service rk3308bs-display-modules.service rk3308bs-grow-rootfs.service; do
        if [[ -f "$overlay_systemd/$unit" ]]; then
            sudo install -m 0644 "$overlay_systemd/$unit" "$MNT/etc/systemd/system/$unit"
            sudo ln -sf "../$unit" "$MNT/etc/systemd/system/multi-user.target.wants/$unit"
        fi
    done

    for motd_script in "$overlay_motd"/*; do
        [[ -f "$motd_script" ]] || continue
        sudo install -m 0755 "$motd_script" "$MNT/etc/update-motd.d/$(basename "$motd_script")"
    done
}

install_board_runtime_scripts

BUILD_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
if [[ "$BOOT_MODE" == "armbian" ]]; then
    BOOT_PHASE="armbian-kernel-custom-rootfs"
else
    BOOT_PHASE="factory-kernel-custom-rootfs"
fi
sudo tee "$MNT/etc/rk3308bs-release" >/dev/null <<EOF
RK3308BS_IMAGE_VERSION=$VERSION
RK3308BS_IMAGE_BUILD=$BUILD_TS
RK3308BS_BOARD=rockchip,rk3308bs-evb-m1soc
RK3308BS_BOOT_PHASE=$BOOT_PHASE
RK3308BS_CONSOLE=$CONSOLE
EOF

if [[ "$BOOT_MODE" != "armbian" && -d "$MODULES_DIR" && -f "$MODULES_DIR/KERNEL_VERSION" ]]; then
    FKVER="$(cat "$MODULES_DIR/KERNEL_VERSION")"
    echo "Injecting factory kernel modules for $FKVER ..."
    sudo mkdir -p "$MNT/lib/modules/$FKVER/extra"
    if compgen -G "$MODULES_DIR/$FKVER/extra/*.ko" >/dev/null; then
        sudo cp -a "$MODULES_DIR/$FKVER/extra/"*.ko "$MNT/lib/modules/$FKVER/extra/"
    fi
    for f in modules.dep modules.dep.bin modules.alias modules.alias.bin modules.softdep; do
        [[ -f "$MODULES_DIR/$FKVER/$f" ]] && sudo cp "$MODULES_DIR/$FKVER/$f" "$MNT/lib/modules/$FKVER/" || true
    done
    sudo mkdir -p "$MNT/etc/modules-load.d"
    echo "8189fs" | sudo tee "$MNT/etc/modules-load.d/rk3308bs-wifi.conf" >/dev/null
fi

sudo mkdir -p "$MNT/etc/rk3308bs"
echo "$VERSION $BUILD_TS" | sudo tee "$MNT/etc/rk3308bs/upgrade-manifest.txt" >/dev/null

sudo mkdir -p "$MNT/lib/firmware"
# Must be exactly GOODIX_CONFIG_911_LENGTH (186) bytes -- drivers/input/touchscreen/goodix.c
# rejects any other length with "The length of the config fw is not correct" and the
# touchscreen never creates an input device. THIS script runs later than the chroot
# hook, directly writing into the final mounted rootfs partition, and always wins as the
# last writer -- so it must carry the SAME 186-byte blob as
# userpatches-chroot/20-rk3308bs-hardware.sh.
#
# We ship the native FACTORY config (X out res 1080 = 0x0438, Y out res 1920 =
# 0x0780, 0x804D module-switch1 = 0x3d: keep swap bit3, no axis reverse;
# checksum byte[184] = 0x89, config_fresh byte[185] = 1). This keeps the GT911
# reporting in its native ~1080x1920 coordinate space, which is exactly the
# space the driver-side fold-fix was calibrated against
# (patches/0015-input-touchscreen-goodix-rk3308bs-fold-fix.patch): that patch
# unfolds the folded horizontal axis and rescales to the panel in the driver,
# so the chip config must NOT be reprogrammed to 480x272 here.
GOODIX_CFG_HEX="00380480070a3d0001ca280a5a3c0a040000000011110017191e149535ff2e30091900000001041c00000000000000000000001941944502070000049a1b008521ff7428006631005b3b005b0000000000000000000000000000000000000000000000000000000000000000000000001d1c1b1a191817161514131211100f0e0d0c0b0a090807060504030201002a292827262524232221201f1e1d1c1b191817161514131211100f0e0d0c0b0a090807060504030201008901"
GOODIX_CFG_LEN=$(( ${#GOODIX_CFG_HEX} / 2 ))
if [[ "$GOODIX_CFG_LEN" -ne 186 ]]; then
    echo "[ERROR] goodix_911_cfg.bin blob must be 186 bytes, got $GOODIX_CFG_LEN" >&2
    exit 1
fi
printf '%s' "$GOODIX_CFG_HEX" | xxd -r -p | sudo tee "$MNT/lib/firmware/goodix_911_cfg.bin" >/dev/null

sudo umount "$MNT"

if [[ "$SHRINK" == "1" ]]; then
    command -v resize2fs >/dev/null || { echo "Install e2fsprogs for resize2fs"; exit 1; }
    echo "=== Shrink rootfs to minimum size (faster flash) ==="
    sudo e2fsck -f -y "$ROOTFS_IMG"
    sudo resize2fs -M "$ROOTFS_IMG"
fi

if [[ -n "$ROOT_UUID" ]]; then
    CMDLINE="earlycon=uart8250,mmio32,0xff0d0000 console=${CONSOLE} root=PARTUUID=${ROOT_UUID} rootfstype=ext4 rw rootwait loglevel=7"
else
    CMDLINE="earlycon=uart8250,mmio32,0xff0d0000 console=${CONSOLE} root=/dev/mmcblk0p${EMMC_ROOT_PART} rootfstype=ext4 rw rootwait loglevel=7"
fi

BOOTIMG="$OUT_DIR/boot.img"
if [[ "$BOOT_MODE" == "armbian" ]]; then
    echo "=== Build Phase B boot.img (Armbian kernel + custom DTB) ==="
    bash "$SCRIPT_DIR/tools/build-armbian-bootimg.sh" \
        --armbian "$ARMBIAN_IMG" \
        --out "$BOOTIMG" \
        --factory "$FACTORY_DIR" \
        --console "$CONSOLE" \
        ${ROOT_UUID:+--root-uuid "$ROOT_UUID"}
else
    echo "=== Phase A: patch factory boot.img cmdline only ==="
    bash "$PATCH_BOOT" "$FACTORY_DIR/boot.img" "$BOOTIMG" "$CMDLINE"
fi

echo "=== Stage Rockchip pack_input ==="
UBOOT_SRC="$FACTORY_DIR/uboot.img"
if [[ "$BOOT_MODE" == "armbian" ]]; then
    echo "=== Patch U-Boot memory layout for Armbian 6.18 kernel size ==="
    UBOOT_PATCHED="$OUT_DIR/_uboot-memlayout.img"
    python3 "$PATCH_UBOOT_MEMLAYOUT" "$FACTORY_DIR/uboot.img" "$UBOOT_PATCHED"
    UBOOT_SRC="$UBOOT_PATCHED"
fi

cp "$FACTORY_DIR/MiniLoaderAll.bin" \
   "$FACTORY_DIR/trust.img" "$UBOOT_SRC" \
   "$FACTORY_DIR/misc.img" "$FACTORY_DIR/recovery.img" "$IMAGE/"
if [[ "$BOOT_MODE" == "armbian" ]]; then
    mv -f "$IMAGE/$(basename "$UBOOT_SRC")" "$IMAGE/uboot.img"
fi
cp "$BOOTIMG" "$ROOTFS_IMG" "$IMAGE/"
echo "=== Patch parameter.txt boot partition for boot.img size ==="
python3 "$SCRIPT_DIR/tools/patch-parameter-boot-size.py" \
    "$FACTORY_DIR/parameter.txt" "$BOOTIMG" "$IMAGE/parameter.txt"
cp "$FACTORY_DIR/package-file" "$PACK/"

ROOTFS_BYTES=$(wc -c < "$ROOTFS_IMG" | tr -d ' ')
cat >"$OUT_DIR/manifest.json" <<EOF
{
  "board": "rk3308bs-evb-m1soc",
  "version": "$VERSION",
  "built": "$BUILD_TS",
  "rootfs_bytes": $ROOTFS_BYTES,
  "rootfs_uuid": "${ROOT_UUID:-}",
  "console": "$CONSOLE",
  "armbian_source": "$(basename "$ARMBIAN_IMG")",
  "boot_phase": "$BOOT_PHASE",
  "flash": "RKDevTool Upgrade Firmware -- allow 5-8 min for rootfs write"
}
EOF

echo ""
echo "Staging complete: $PACK"
echo "  rootfs.img: $(du -h "$ROOTFS_IMG" | cut -f1) ($ROOTFS_BYTES bytes)"
echo "  manifest:   $OUT_DIR/manifest.json"
echo ""
echo "Next: monolithic packaging via tools/pack-firmware-linux.sh"
