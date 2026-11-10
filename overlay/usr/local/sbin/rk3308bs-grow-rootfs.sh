#!/bin/bash
# Grow the ext4 rootfs to fill its eMMC partition on first boot (resize2fs only).
# The GPT is never touched: the layout is fixed by parameter.txt and the factory bootloader
# reads fixed offsets, so Armbian's growpart-based resize service is disabled by
# 25-rk3308bs-emmc-layout.sh. Needed because the image is packed at a shrunk size.
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
