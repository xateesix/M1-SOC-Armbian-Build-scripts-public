#!/bin/bash
# Safely grow the ext4 rootfs filesystem to fill its existing eMMC partition on first boot.
#
# Unlike Armbian's stock armbian-resize-filesystem.service (intentionally disabled by
# 25-rk3308bs-emmc-layout.sh), this does NOT touch the GPT partition table -- our
# eMMC's partition layout is fixed by parameter.txt (the factory bootloader chain
# reads fixed offsets for MiniLoader/uboot/trust/boot/rootfs) and must never be
# resized/rewritten by growpart-style tools. This script only runs `resize2fs` on
# the already-existing, already-correctly-sized rootfs PARTITION, which is a safe,
# purely-filesystem-level operation with no partition-table risk at all.
#
# Needed because: the rootfs image is built/packed at a shrunk size (for faster
# flashing), but the actual eMMC partition it gets written into is already the
# full ~7.2GB fixed size -- without this, the filesystem never grows to use that
# space (discovered 2026-08-31 on v91: `df` showed 1.6G/97% used inside a 7.2GB
# partition, once 25-rk3308bs-emmc-layout.sh started actually running for the
# first time ever and disabling Armbian's own resize service that would have
# otherwise grown it, unsafely, via the GPT-modifying path).
set -euo pipefail

FLAG=/root/.rk3308bs-rootfs-grown
[[ -f "$FLAG" ]] && exit 0

ROOTDEV="$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')"
if [[ -z "$ROOTDEV" ]]; then
	echo "[rk3308bs] Could not determine root device, skipping filesystem grow" >&2
	exit 0
fi

echo "[rk3308bs] Growing ext4 filesystem on $ROOTDEV to fill its existing partition ..."
if resize2fs "$ROOTDEV"; then
	touch "$FLAG"
	echo "[rk3308bs] Rootfs filesystem grown successfully"
else
	echo "[rk3308bs] resize2fs failed -- will retry on next boot (flag not set)" >&2
	exit 1
fi
