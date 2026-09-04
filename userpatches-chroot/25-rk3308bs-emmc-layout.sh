#!/bin/bash
# RK3308BS eMMC uses a fixed Rockchip GPT from parameter.txt  -  do NOT grow rootfs.
set -euo pipefail

echo "[rk3308bs] Disabling Armbian rootfs resize (fixed eMMC GPT layout) ..."

# Official Armbian skip flag (see packages/bsp/common/usr/lib/armbian/armbian-resize-filesystem)
touch /root/.no_rootfs_resize

systemctl disable armbian-resize-filesystem.service 2>/dev/null || true
systemctl mask armbian-resize-filesystem.service 2>/dev/null || true
rm -f /etc/systemd/system/basic.target.wants/armbian-resize-filesystem.service

# growroot initramfs hook also expands partitions on some images
if [[ -f /usr/share/initramfs-tools/hooks/growroot ]]; then
	mv /usr/share/initramfs-tools/hooks/growroot \
		/usr/share/initramfs-tools/hooks/growroot.disabled 2>/dev/null || true
fi
if [[ -f /usr/share/initramfs-tools/scripts/local-bottom/growroot ]]; then
	mv /usr/share/initramfs-tools/scripts/local-bottom/growroot \
		/usr/share/initramfs-tools/scripts/local-bottom/growroot.disabled 2>/dev/null || true
fi

# Cosmetic: armbian-quotes needs network/fortune and exits 6 on headless boards
if [[ -f /etc/cron.daily/armbian-quotes ]]; then
	chmod -x /etc/cron.daily/armbian-quotes 2>/dev/null || true
fi

echo "[rk3308bs] Fixed eMMC layout preserved (/root/.no_rootfs_resize)"
