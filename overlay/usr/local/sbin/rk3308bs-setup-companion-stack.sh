#!/bin/bash
# Interactive post-first-boot setup for this board's companion role: KlipperScreen
# (touchscreen UI) + Crowsnest (camera stream) connecting to a REMOTE Klipper +
# Moonraker host (a separate "main" printer-control board). This board does NOT
# run Klipper itself -- it is a client/companion device only.
#
# Only KIAUH is pre-staged at build time (userpatches-chroot/35-rk3308bs-companion-stack.sh,
# see /etc/rk3308bs/companion-stack.env). KIAUH downloads KlipperScreen and
# Crowsnest itself. This script's job is just to: (1) collect the remote host's
# IP interactively, (2) seed ~/printer_data/config sample configs wired to that
# host, (3) make KIAUH trivially easy to launch, and (4) hand off to KIAUH's own
# interactive installer for the actual KlipperScreen/Crowsnest install -- KIAUH
# handles its own OS package dependencies, so we deliberately do not duplicate
# that logic here.
set -euo pipefail

# This script MUST run as the normal login user, never as root/sudo. It
# configures the invoking user's home (~/.config, ~/printer_data) and fixes
# ownership of the staged /opt repos to that user; running it as root would
# create root-owned config in /root and re-root the /opt repos, breaking the
# very "Permission denied" cases the ownership fixup below exists to prevent.
# It elevates with sudo internally only for the few system-file writes.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "Error: run this as your normal login user, NOT as root and NOT with sudo." >&2
	echo "  It sets up your user's home and the /opt companion repos for that user." >&2
	echo "  Just run:  rk3308bs-setup-companion-stack" >&2
	exit 1
fi

ENV_FILE=/etc/rk3308bs/companion-stack.env
DONE_FLAG=/etc/rk3308bs/.companion-stack-configured

if [[ ! -f "$ENV_FILE" ]]; then
	echo "Error: $ENV_FILE not found -- companion stack was not staged at build time." >&2
	echo "(Expected from userpatches-chroot/35-rk3308bs-companion-stack.sh)" >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

RUN_USER="$(id -un)"

# KIAUH is meant to live in the user's home (~/kiauh): it writes its own
# kiauh.ini/kiauh.cfg and logs inside its own directory and assumes a per-user
# home install. It is pre-staged read-only under /opt at build time, so on first
# run relocate it into the invoking user's home and run it from there. Copy
# (not move) so a re-flash-free re-run still has the /opt seed to restore from;
# the /opt seed is left in place as the pristine source.
KIAUH_HOME="$HOME/kiauh"
if [[ ! -d "$KIAUH_HOME" ]]; then
	if [[ -d "${KIAUH_DIR:-}" ]]; then
		echo "Placing KIAUH in your home directory ($KIAUH_HOME) ..."
		cp -a "$KIAUH_DIR" "$KIAUH_HOME"
	else
		echo "Error: KIAUH not found at ${KIAUH_DIR:-<unset>} and no $KIAUH_HOME --" >&2
		echo "companion stack was not staged correctly." >&2
		exit 1
	fi
fi
# Ensure the home copy is owned by (and writable to) the invoking user, and mark
# it a git safe.directory so KIAUH's self-update git calls don't refuse it.
if [[ "$(stat -c '%U' "$KIAUH_HOME" 2>/dev/null)" != "$RUN_USER" ]]; then
	sudo chown -R "$RUN_USER:$RUN_USER" "$KIAUH_HOME" 2>/dev/null || true
fi
git config --global --add safe.directory "$KIAUH_HOME" 2>/dev/null || true

echo "=== RK3308BS Companion Stack Setup (KlipperScreen + Crowsnest) ==="
echo "This board acts as a CLIENT ONLY -- it does not run Klipper locally."
echo "You will need the IP address of your main Klipper/Moonraker host."
echo

read -r -p "Main host IP address or hostname [${MOONRAKER_HOST}]: " input_host
MOONRAKER_HOST="${input_host:-$MOONRAKER_HOST}"
if [[ -z "$MOONRAKER_HOST" || "$MOONRAKER_HOST" == "unconfigured-host" ]]; then
	echo "Error: a real host IP/hostname is required." >&2
	exit 1
fi

read -r -p "Moonraker port [${MOONRAKER_PORT}]: " input_port
MOONRAKER_PORT="${input_port:-$MOONRAKER_PORT}"

read -r -p "Crowsnest local stream port [${CROWSNEST_PORT}]: " input_cport
CROWSNEST_PORT="${input_cport:-$CROWSNEST_PORT}"

echo
echo "Testing connectivity to ${MOONRAKER_HOST}:${MOONRAKER_PORT} ..."
if command -v curl >/dev/null 2>&1 && curl --max-time 3 -s -o /dev/null "http://${MOONRAKER_HOST}:${MOONRAKER_PORT}/server/info"; then
	echo "  OK: Moonraker responded."
else
	echo "  Warning: could not reach Moonraker there yet (this is fine if that host isn't up)." >&2
fi

echo "Updating $ENV_FILE ..."
sudo sed -i \
	-e "s|^MOONRAKER_HOST=.*|MOONRAKER_HOST=${MOONRAKER_HOST}|" \
	-e "s|^MOONRAKER_PORT=.*|MOONRAKER_PORT=${MOONRAKER_PORT}|" \
	-e "s|^CROWSNEST_PORT=.*|CROWSNEST_PORT=${CROWSNEST_PORT}|" \
	"$ENV_FILE"

# Companion configs live in the standard Klipper data dir so KIAUH-installed
# KlipperScreen and Crowsnest auto-detect them (~/printer_data/config/...).
# ~/printer_data/config/KlipperScreen.conf is one of KlipperScreen's default
# search paths; ~/printer_data/config/crowsnest.conf is Crowsnest's default.
CONFIG_DIR="$HOME/printer_data/config"
mkdir -p "$CONFIG_DIR" "$HOME/printer_data/logs"

KLIPPERSCREEN_CONF="$CONFIG_DIR/KlipperScreen.conf"
if [[ ! -f "$KLIPPERSCREEN_CONF" ]]; then
	cat >"$KLIPPERSCREEN_CONF" <<EOF
# KlipperScreen configuration -- this board is a CLIENT ONLY and connects to a
# remote Klipper/Moonraker host running on your main printer-control board.
# Docs: https://klipperscreen.github.io/KlipperScreen/
[printer Main Printer]
moonraker_host: ${MOONRAKER_HOST}
moonraker_port: ${MOONRAKER_PORT}

[main]
show_cursor: false
EOF
	echo "Created sample $KLIPPERSCREEN_CONF"
else
	sed -i \
		-e "s|^moonraker_host:.*|moonraker_host: ${MOONRAKER_HOST}|" \
		-e "s|^moonraker_port:.*|moonraker_port: ${MOONRAKER_PORT}|" \
		"$KLIPPERSCREEN_CONF"
	echo "Updated $KLIPPERSCREEN_CONF"
fi

CROWSNEST_CONF="$CONFIG_DIR/crowsnest.conf"
if [[ ! -f "$CROWSNEST_CONF" ]]; then
	cat >"$CROWSNEST_CONF" <<EOF
# Crowsnest configuration for a camera attached locally to this companion board.
# Adjust [cam 1] to match your camera (device, resolution, mode).
# Docs: https://github.com/mainsail-crew/crowsnest
[crowsnest]
log_path: ~/printer_data/logs
log_level: verbose
delete_log: false
no_proxy: false

[cam 1]
mode: ustreamer
enable_rtsp: false
rtsp_port: 8554
port: ${CROWSNEST_PORT}
device: /dev/video0
resolution: 640x480
max_fps: 15
EOF
	echo "Created sample $CROWSNEST_CONF"
else
	sed -i -e "s|^port:.*|port: ${CROWSNEST_PORT}|" "$CROWSNEST_CONF"
	echo "Updated $CROWSNEST_CONF"
fi

# Make KIAUH trivially launchable from anywhere. The wrapper refreshes the apt
# index first: the image ships with a build-time apt list that goes stale, so
# KIAUH's `apt-get install` (run without its own `apt update`) hits superseded
# pool entries and fails with 404s. Mirrors the manual recovery
# (rm -rf /var/lib/apt/lists/*; apt clean; apt update) needed on the board.
if [[ ! -e /usr/local/bin/kiauh ]]; then
	sudo tee /usr/local/bin/kiauh >/dev/null <<KIAUH_LAUNCHER
#!/bin/bash
echo "[kiauh] Refreshing apt package index (avoids stale-repo 404s) ..."
sudo rm -rf /var/lib/apt/lists/*
sudo apt-get clean
sudo apt-get update || echo "[kiauh] apt update reported issues; continuing"
exec bash "\$HOME/kiauh/kiauh.sh" "\$@"
KIAUH_LAUNCHER
	sudo chmod 0755 /usr/local/bin/kiauh
fi

sudo mkdir -p "$(dirname "$DONE_FLAG")"
sudo tee "$DONE_FLAG" >/dev/null <<EOF
configured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
moonraker_host=${MOONRAKER_HOST}
moonraker_port=${MOONRAKER_PORT}
crowsnest_port=${CROWSNEST_PORT}
EOF

echo
echo "=== Configuration saved ==="
echo "Remote host:      ${MOONRAKER_HOST}:${MOONRAKER_PORT}"
echo "Crowsnest port:   ${CROWSNEST_PORT}"
echo "Config dir:       ${CONFIG_DIR}"
echo "  - KlipperScreen.conf (edit [printer Main Printer] if needed)"
echo "  - crowsnest.conf     (edit [cam 1] for your camera)"
echo
echo "Next: KIAUH will open so you can install KlipperScreen and Crowsnest."
echo "(Klipper and Moonraker do NOT need to be installed on this board --"
echo " they should already be running on your main printer-control board.)"
echo
read -r -p "Press Enter to launch KIAUH now, or Ctrl-C to do it later (just run: kiauh) "
# Refresh the apt index before KIAUH installs packages. The image's build-time
# apt lists go stale, so KIAUH's apt-get install would otherwise query dead pool
# entries and 404. This is the same fix baked into the /usr/local/bin/kiauh
# wrapper above, applied here for the first (in-setup) launch too.
echo "Refreshing apt package index (avoids stale-repo 404s) ..."
sudo rm -rf /var/lib/apt/lists/*
sudo apt-get clean
sudo apt-get update || echo "apt update reported issues; continuing to KIAUH"
exec bash "$KIAUH_HOME/kiauh.sh"
