#!/bin/bash
# Bake locale, timezone, users and WiFi into the rootfs during compile.sh.
# Currently a no-op: ROOT_PASSWORD/USER_*/WIFI_* never reach this hook as environment
# variables. Credentials arrive through PRESET_* in firstboot.conf (Armbian first-login
# wizard), so the hook exits 0 instead of failing the build.
# TODO: export those variables so PRECONFIGURE_CREDENTIALS=1 can skip the wizard, or retire this hook.
set -euo pipefail

if [[ -z "${ROOT_PASSWORD:-}" ]]; then
    echo "[rk3308bs] ROOT_PASSWORD not set in this hook's environment -- skipping build-time"
    echo "[rk3308bs] credential baking (relying on firstboot.conf/PRESET_* instead, which is"
    echo "[rk3308bs] the proven working mechanism). This is expected/known, not an error."
    exit 0
fi

ROOT_PASSWORD="${ROOT_PASSWORD:?ROOT_PASSWORD required}"
USER_NAME="${USER_NAME:-m1prox1}"
USER_PASSWORD="${USER_PASSWORD:-$ROOT_PASSWORD}"
USER_REALNAME="${USER_REALNAME:-$USER_NAME}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Los_Angeles}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

export DEBIAN_FRONTEND=noninteractive

echo "[rk3308bs] Pre-configuring root password ..."
echo "root:${ROOT_PASSWORD}" | chpasswd -c SHA512

echo "[rk3308bs] Locale ${LOCALE} ..."
if grep -q "^# ${LOCALE} UTF-8" /etc/locale.gen 2>/dev/null; then
	sed -i "s/^# ${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
elif ! grep -q "^${LOCALE} UTF-8" /etc/locale.gen 2>/dev/null; then
	echo "${LOCALE} UTF-8" >> /etc/locale.gen
fi
locale-gen "${LOCALE}" >/dev/null 2>&1 || locale-gen
update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}" LANGUAGE="${LOCALE}"

echo "[rk3308bs] Timezone ${TIMEZONE} ..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" >/etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

echo "[rk3308bs] User ${USER_NAME} ..."
if ! id "$USER_NAME" &>/dev/null; then
	useradd -m -s /bin/bash -c "$USER_REALNAME" "$USER_NAME"
fi
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd -c SHA512
usermod -aG sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,input,render,netdev "$USER_NAME" 2>/dev/null \
	|| usermod -aG sudo "$USER_NAME"

if [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]]; then
	echo "[rk3308bs] WiFi ${WIFI_SSID} (NetworkManager profile) ..."
	# Remove any base-image netplan config so it can't compete with NM.
	rm -f /etc/netplan/*.yaml 2>/dev/null || true
	# NetworkManager keyfile connection profile. KlipperScreen's network panel
	# manages WiFi through NM, so the pre-seeded credentials must live here (not
	# in netplan). NM ignores system-connection files unless they are root-owned
	# and chmod 600. Values are literal to end-of-line in keyfile format, so no
	# YAML-style quoting/escaping is needed.
	NM_UUID="$(cat /proc/sys/kernel/random/uuid)"
	mkdir -p /etc/NetworkManager/system-connections
	cat >/etc/NetworkManager/system-connections/rk3308bs-wifi.nmconnection <<EOF
[connection]
id=rk3308bs-wifi
uuid=${NM_UUID}
type=wifi
interface-name=wlan0
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASSWORD}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
	chmod 600 /etc/NetworkManager/system-connections/rk3308bs-wifi.nmconnection
	chown root:root /etc/NetworkManager/system-connections/rk3308bs-wifi.nmconnection
	ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

rm -f /root/.not_logged_in_yet
echo "[rk3308bs] First-boot wizard disabled (.not_logged_in_yet removed)"
