#!/bin/bash
# Runs inside Armbian chroot during compile.sh (userpatches/customize-image.sh hook).
# Userland packages and services for Artillery M1 Pro S1-SOC (RK3308BS) hardware.
set -euo pipefail

echo "[rk3308bs] Installing board hardware userland packages ..."
export DEBIAN_FRONTEND=noninteractive
# Reset the apt package index inside the chroot before the first update/install.
# The base rootfs can carry a stale/partial /var/lib/apt/lists from the Armbian
# debootstrap cache, which makes apt try to fetch specific pinned .deb versions
# that have since been superseded in the Debian pool -- producing hard
# "404 Not Found" fetch failures (e.g. python3-filelock_3.9.0-1) that abort the
# install and later break on-device apt (KIAUH/KlipperScreen deps). Clearing the
# lists + cache and re-running update forces a fresh index that matches what's
# actually in the pool now. Mirrors the manual recovery
# (rm -rf /var/lib/apt/lists/*; apt clean; apt update) done on the board.
rm -rf /var/lib/apt/lists/*
apt-get -o APT::Sandbox::User=root clean
# APT::Sandbox::User=root works around a well-known apt-in-chroot failure mode:
# apt-get's default sandboxing drops to the unprivileged "_apt" user for GPG
# verification, whose temp-file access can be broken this early in a freshly
# populated chroot ("Couldn't create temporary file /tmp/apt.conf.XXXXXX for
# passing config to apt-key" / "repository is not signed" on every source, even
# base Debian ones). Confirmed via v89/v90 builds: this exact error aborted the
# entire script (set -euo pipefail) before ever reaching the netplan patch step
# below, once customize_image() started actually being invoked (see that fix's
# commit for why it wasn't invoked at all before).
apt-get -o APT::Sandbox::User=root update -qq
apt-get -o APT::Sandbox::User=root install -y -qq --no-install-recommends \
    network-manager \
    wpasupplicant \
    iw \
    wireless-tools \
    rfkill \
    firmware-realtek \
    i2c-tools \
    evtest \
    libinput-tools \
    kmod \
    python3 \
    ca-certificates \
    policykit-1

# polkit.service ships as a "static" unit (no [Install] section) meant to be
# D-Bus-activated on demand -- systemctl enable is a no-op for it. During
# Armbian's own first-boot wizard (armbian-firstlogin), timedatectl's very
# first call can race D-Bus activation and lose, printing "Failed to set time
# zone: Access denied" even though policykit-1 is correctly installed
# (confirmed live on v92: retrying the exact same command moments later, after
# polkit had a chance to start, succeeded). Force it to actually start at boot
# via a direct symlink, the same technique already used for our own
# wifi/display/grow-rootfs services.
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/polkit.service /etc/systemd/system/multi-user.target.wants/polkit.service

# NetworkManager is the network stack for this image: KlipperScreen's built-in
# network panel talks to NM over D-Bus, so wlan0 must be managed by NM (not
# netplan/systemd-networkd). Disable networkd to avoid a two-manager conflict.
systemctl disable systemd-networkd.service 2>/dev/null || true
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable systemd-resolved.service 2>/dev/null || true

# Force NM to manage every device, overriding any Armbian/base default that
# hands wlan0 to systemd-networkd and marks it unmanaged in NM.
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/10-rk3308bs.conf <<'EOF'
[keyfile]
unmanaged-devices=none
EOF
chmod 0644 /etc/NetworkManager/conf.d/10-rk3308bs.conf

# Any netplan YAML left by the base image would be inert now that netplan.io is
# gone, but remove it so nothing references the old networkd renderer.
rm -f /etc/netplan/*.yaml 2>/dev/null || true

mkdir -p /lib/firmware
python3 - <<'PY'
from pathlib import Path

fw = Path("/lib/firmware/goodix_911_cfg.bin")
# Must be exactly GOODIX_CONFIG_911_LENGTH (186) bytes -- drivers/input/touchscreen/goodix.c
# rejects any other length with "The length of the config fw is not correct" and the
# touchscreen never creates an input device.
#
# The mainline goodix driver UPLOADS this file to the GT911 at probe (load_cfg_from_disk
# path -> goodix_send_cfg), so these bytes define the chip's live output space. The
# DT goodix.cfg-group0 array is a rockchip-vendor property that mainline ignores; this
# file is the real source of truth for resolution/orientation.
#
# GT911 config layout (base reg 0x8047): [0]=version, [1..2]=X out res LE,
# [3..4]=Y out res LE, [5]=max contacts, [6]=0x804D module-switch1
# (bit3=swap X/Y, bit6/bit7=reverse axes), [184]=checksum ((~sum(0..183))+1),
# [185]=config_fresh (must be 1).
#
# We ship the native FACTORY config (below), NOT a reprogrammed 480x272 one.
# Parsed per the layout above: [1..2] X out res = 0x0438 (1080), [3..4] Y out
# res = 0x0780 (1920), [6] 0x804D = 0x3d (swap bit3 set, no axis reverse),
# [184] checksum = 0x89, [185] config_fresh = 1.
#
# Rationale: the GT911 horizontal axis is folded ("double width") in hardware --
# a dead gap the chip never emits -- and this is intrinsic to the digitizer, so
# no chip config removes it. Rather than reprogram the chip, we keep it in its
# native ~1080x1920 space and correct coordinates in the driver via
# patches/0015-input-touchscreen-goodix-rk3308bs-fold-fix.patch (unfold the fold
# + rescale to the panel). That patch's constants are calibrated against THIS
# native space, so the chip must stay in the factory config here.
data = bytes.fromhex(
    "00 38 04 80 07 0a 3d 00 01 ca 28 0a 5a 3c 0a 04 00 00 00 00 11 11 "
    "00 17 19 1e 14 95 35 ff 2e 30 09 19 00 00 00 01 04 1c 00 00 00 00 "
    "00 00 00 00 00 00 00 19 41 94 45 02 07 00 00 04 9a 1b 00 85 21 ff "
    "74 28 00 66 31 00 5b 3b 00 5b 00 00 00 00 00 00 00 00 00 00 00 00 "
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "
    "00 00 1d 1c 1b 1a 19 18 17 16 15 14 13 12 11 10 0f 0e 0d 0c 0b 0a "
    "09 08 07 06 05 04 03 02 01 00 2a 29 28 27 26 25 24 23 22 21 20 1f "
    "1e 1d 1c 1b 19 18 17 16 15 14 13 12 11 10 0f 0e 0d 0c 0b 0a 09 08 "
    "07 06 05 04 03 02 01 00 89 01"
)
assert len(data) == 186, f"goodix config blob must be 186 bytes, got {len(data)}"
if not fw.exists() or fw.read_bytes() != data:
    fw.write_bytes(data)
PY

mkdir -p /usr/local/sbin /etc/systemd/system
cat >/usr/local/sbin/rk3308bs-load-wifi.sh <<'EOF'
#!/bin/bash
set -euo pipefail

modprobe rfkill
modprobe libarc4
modprobe cfg80211
modprobe mac80211
modprobe 8189fs
EOF
chmod 0755 /usr/local/sbin/rk3308bs-load-wifi.sh

cat >/etc/systemd/system/rk3308bs-wifi-modules.service <<'EOF'
[Unit]
Description=RK3308BS load 8189fs WiFi modules before networking
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target NetworkManager.service

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/rk3308bs-load-wifi.sh
RemainAfterExit=yes
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/rk3308bs-wifi-modules.service
systemctl enable rk3308bs-wifi-modules.service 2>/dev/null || true

cat >/usr/local/sbin/rk3308bs-load-display.sh <<'EOF'
#!/bin/bash
set -euo pipefail

for bl in /sys/class/backlight/*; do
    [ -f "$bl/brightness" ] || continue
    echo 255 > "$bl/brightness" 2>/dev/null || true
    if [ -f "$bl/bl_power" ]; then
        echo 0 > "$bl/bl_power" 2>/dev/null || true
    fi
done
EOF
chmod 0755 /usr/local/sbin/rk3308bs-load-display.sh

cat >/etc/systemd/system/rk3308bs-display-modules.service <<'EOF'
[Unit]
Description=RK3308BS LCD/backlight bring-up
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/rk3308bs-load-display.sh
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/rk3308bs-display-modules.service
systemctl enable rk3308bs-display-modules.service 2>/dev/null || true

# First-boot WiFi recovery: the RTL8189FS SDIO WiFi reliably associates from the
# second boot on, but often fails to get an IP on the very first boot. This unit
# (shipped in the overlay) reboots exactly once, only if wlan0 has no IP after a
# settle window, guarded by a marker so it can never boot-loop.
if [[ -f /usr/local/sbin/rk3308bs-wifi-firstboot-recover.sh ]]; then
    chmod 0755 /usr/local/sbin/rk3308bs-wifi-firstboot-recover.sh
fi
if [[ -f /etc/systemd/system/rk3308bs-wifi-firstboot-recover.service ]]; then
    chmod 0644 /etc/systemd/system/rk3308bs-wifi-firstboot-recover.service
    systemctl enable rk3308bs-wifi-firstboot-recover.service 2>/dev/null || true
fi

# Console: Armbian 6.18 has no fiq-debugger  -  use raw UART3 (ttyS3 @ 1500000).
# Factory DTB keeps OTP/thermal; fiq-debugger disabled at pack time (--armbian-serial).
mkdir -p /etc/systemd/system/serial-getty@ttyS3.service.d
cat >/etc/systemd/system/serial-getty@ttyS3.service.d/baud1500000.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --keep-baud 115200,1500000,9600 %I $TERM
EOF
systemctl enable serial-getty@ttyS3.service 2>/dev/null || true
systemctl disable serial-getty@ttyFIQ0.service 2>/dev/null || true

mkdir -p /etc/rk3308bs
cat >/etc/rk3308bs/hardware.txt <<'EOF'
Board: Artillery M1 Pro S1-SOC (RK3308BS EVB AMIC V11)
Display: 480x272 RGB + Goodix GT911 (i2c-3/0x5d)
LCD policy: boot messages on fb0 during startup, then Klipper UI (no getty/login on panel)
WiFi: RTL8189CS SDIO (rtl8189fs / 8189fs.ko)
LEDs: GPIO green PA6, blue PA5
Serial: ttyS3 @ 1500000 (Armbian  -  factory DTB with fiq-debugger disabled)
EOF

systemctl disable getty@tty1.service 2>/dev/null || true

mkdir -p /usr/local/bin /etc/systemd/system
cat >/usr/local/bin/restore-thermal-trip.sh <<'EOF'
#!/bin/bash
set -euo pipefail

sleep 45

for zone in /sys/class/thermal/thermal_zone*; do
    [ -d "$zone" ] || continue
    for trip in "$zone"/trip_point_*_temp; do
        [ -f "$trip" ] || continue
        current="$(cat "$trip" 2>/dev/null || true)"
        if [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -ge 120000 ]; then
            echo 115000 > "$trip"
            echo "restored $zone $(basename "$trip") -> 115000"
        fi
    done
done
EOF
chmod 0755 /usr/local/bin/restore-thermal-trip.sh

cat >/etc/systemd/system/restore-thermal-trip.service <<'EOF'
[Unit]
Description=Restore thermal trip points after boot
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/restore-thermal-trip.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable restore-thermal-trip.service 2>/dev/null || true

# Install system diagnosis and validation scripts from the overlay or regenerate them
# if the bind-mount is absent. This is required for the final rootfs to contain the
# board diagnostic and validation entrypoints.
install_overlay_scripts() {
    local overlay_root="${OVERLAY_ROOT:-/tmp/overlay}"
    local script

    mkdir -p /usr/local/sbin
    for script in rk3308bs-validation.sh rk3308bs-diagnose.sh; do
        local source_path="${overlay_root}/usr/local/sbin/${script}"
        if [[ -f "$source_path" ]]; then
            cp "$source_path" "/usr/local/sbin/$script"
            chmod 0755 "/usr/local/sbin/$script"
            echo "[rk3308bs] Installed /usr/local/sbin/$script from overlay"
        elif [[ -f "/usr/local/sbin/$script" ]]; then
            chmod 0755 "/usr/local/sbin/$script"
            echo "[rk3308bs] Verified /usr/local/sbin/$script already present"
        else
            echo "[rk3308bs] WARNING: missing board validation/diagnostic script: $script"
        fi
    done
}

install_overlay_scripts

echo "[rk3308bs] Hardware userland configured"
