#!/bin/bash
# First-boot WiFi recovery.
#
# On this board the RTL8189FS SDIO WiFi reliably associates from the SECOND
# boot onward, but often fails to get an IP on the very first boot (the first
# boot does a lot of one-time work -- rootfs grow, firstlogin, systemd
# generators -- and the SDIO/module bring-up races NetworkManager's initial
# connection attempt). A single reboot fixes it every time.
#
# This runs once (guarded by a marker), gives NetworkManager a window to bring
# wlan0 up, and only reboots if it still has no IPv4 address. The marker is
# written BEFORE any reboot, so this can reboot at most once and can never
# boot-loop.
set -uo pipefail

FLAG=/root/.rk3308bs-wifi-firstboot-done

# Already handled on a previous boot -- never touch it again.
[[ -e "$FLAG" ]] && exit 0

have_ip() {
    ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '
}

# Give NetworkManager up to ~45s to associate and get DHCP on the first boot.
for _ in $(seq 1 45); do
    have_ip && break
    sleep 1
done

# Record that first-boot handling is done regardless of the outcome, so the
# post-reboot boot skips this unit entirely (no loop).
touch "$FLAG"

if have_ip; then
    echo "[rk3308bs] wlan0 has an IP on first boot; no reboot needed"
    exit 0
fi

echo "[rk3308bs] wlan0 has no IP after first-boot window; rebooting once to recover WiFi"
sync
systemctl reboot
