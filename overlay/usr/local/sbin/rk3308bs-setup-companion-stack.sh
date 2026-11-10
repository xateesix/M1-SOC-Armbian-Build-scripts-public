#!/bin/bash
# Interactive post-first-boot setup for the companion role: KlipperScreen (touch UI) and
# Crowsnest (camera stream) against a REMOTE Klipper/Moonraker host. This board does not run Klipper.
# Only KIAUH is pre-staged at build time (see /etc/rk3308bs/companion-stack.env). This script
# collects the remote host IP, seeds ~/printer_data/config samples for it, makes KIAUH easy to
# launch and hands off to KIAUH for the install (KIAUH handles its own package dependencies).
set -euo pipefail

ENV_FILE=/etc/rk3308bs/companion-stack.env
DONE_FLAG=/etc/rk3308bs/.companion-stack-configured

if [[ ! -f "$ENV_FILE" ]]; then
	echo "Error: $ENV_FILE not found -- companion stack was not staged at build time." >&2
	echo "(Expected from userpatches-chroot/35-rk3308bs-companion-stack.sh)" >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ ! -d "${KIAUH_DIR:-}" ]]; then
	echo "Error: KIAUH not found at ${KIAUH_DIR:-<unset>} -- companion stack was not staged correctly." >&2
	exit 1
fi

# The staged repos under /opt were cloned as root at build time and chowned to
# the primary user -- but that chown can silently no-op if the user did not yet
# exist in the chroot when 35-rk3308bs-companion-stack.sh ran, leaving them
# root-owned. That makes KIAUH fail at runtime with "Permission denied" writing
# /opt/kiauh/kiauh.cfg and git "detected dubious ownership". Fix both here, where
# we know the real invoking user, so no manual chmod/chown is ever needed.
RUN_USER="$(id -un)"
for repo_dir in kiauh klipper moonraker KlipperScreen crowsnest; do
	d="/opt/$repo_dir"
	[[ -d "$d" ]] || continue
	if [[ "$(stat -c '%U' "$d" 2>/dev/null)" != "$RUN_USER" ]]; then
		sudo chown -R "$RUN_USER:$RUN_USER" "$d" 2>/dev/null || true
	fi
	git config --global --add safe.directory "$d" 2>/dev/null || true
done

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

KLIPPERSCREEN_CONF="$HOME/.config/KlipperScreen.conf"
mkdir -p "$(dirname "$KLIPPERSCREEN_CONF")"
if [[ ! -f "$KLIPPERSCREEN_CONF" ]]; then
	cp /etc/skel/.config/KlipperScreen.conf "$KLIPPERSCREEN_CONF" 2>/dev/null || true
fi
if [[ -f "$KLIPPERSCREEN_CONF" ]]; then
	sed -i \
		-e "s|^moonraker_host=.*|moonraker_host=${MOONRAKER_HOST}|" \
		-e "s|^moonraker_port=.*|moonraker_port=${MOONRAKER_PORT}|" \
		"$KLIPPERSCREEN_CONF"
	echo "Updated $KLIPPERSCREEN_CONF"
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
exec bash "${KIAUH_DIR}/kiauh.sh" "\$@"
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
exec bash "${KIAUH_DIR}/kiauh.sh"
