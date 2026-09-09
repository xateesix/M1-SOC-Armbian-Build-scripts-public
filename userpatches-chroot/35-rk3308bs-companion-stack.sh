#!/bin/bash
# Download and stage companion-host software used by the S1-SOC image.
#
# This preloads source trees and baseline config for KIAUH, Klipper,
# Moonraker, KlipperScreen, and Crowsnest so the build output already
# contains the companion stack inputs.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Repos live directly under /opt (e.g. /opt/kiauh, /opt/klipper) rather than
# nested under /opt/rk3308bs/companion-stack/repos/ -- flattened per explicit
# user request ("way too deeply buried, they should just be in the opt
# folder"). REPOS_ROOT is kept as a variable (not hardcoded inline below) so
# this can still be overridden via env var if ever needed, without requiring
# another round of path surgery.
REPOS_ROOT="${REPOS_ROOT:-/opt}"
COMPANION_USER="${COMPANION_USER:-m1prox1}"
MOONRAKER_HOST="${MOONRAKER_HOST:-unconfigured-host}"
MOONRAKER_PORT="${MOONRAKER_PORT:-7125}"
CROWSNEST_PORT="${CROWSNEST_PORT:-8080}"

echo "[rk3308bs] Installing companion-stack build prerequisites ..."
# See userpatches-chroot/20-rk3308bs-hardware.sh for why APT::Sandbox::User=root
# is needed here (works around a chroot-specific apt-key temp-file failure).
#
# Deliberately NOT running `apt-get update` again here: 20-rk3308bs-hardware.sh
# (which the fixed hook ordering in userpatches-customize-image.sh guarantees
# always runs before this script) already refreshed the exact same apt lists
# moments earlier, and nothing in between (25-rk3308bs-emmc-layout.sh,
# 30-rk3308bs-preconfigure.sh) touches package state. Confirmed via v95/v96
# build logs: this redundant second `apt-get update` reproducibly failed
# re-reading the just-fetched bookworm-updates InRelease file with
# "getline (12: Cannot allocate memory)", aborting this whole script (set -euo
# pipefail) before it ever reached the git-clone-repos step below -- so the
# companion-stack was never actually staged on either v95 or v96 despite the
# overall build reporting exit_code=0. Removing the redundant call both fixes
# this failure point and avoids wastefully re-fetching identical index files.
apt-get -o APT::Sandbox::User=root install -y -qq --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv \
    rsync \
    unzip

echo "[rk3308bs] Staging companion software under $REPOS_ROOT ..."
mkdir -p "$REPOS_ROOT"

clone_repo() {
    local url="$1"
    local dest="$2"

    if [[ -d "$dest/.git" ]]; then
        git -C "$dest" fetch --depth 1 origin >/dev/null 2>&1 || true
        git -C "$dest" reset --hard FETCH_HEAD >/dev/null 2>&1 || true
        return 0
    fi

    rm -rf "$dest"
    git clone --depth 1 "$url" "$dest"
}

# Only KIAUH is pre-staged. KIAUH is the installer the user runs, and it clones
# Klipper, Moonraker, KlipperScreen, and Crowsnest into the user's home itself
# when its installers run. Pre-cloning those four here only produced unused
# /opt copies that neither this image's setup script nor KIAUH ever referenced,
# so they were removed in favor of KIAUH pulling them down on demand.
clone_repo https://github.com/dw-0/kiauh.git "$REPOS_ROOT/kiauh"

mkdir -p /etc/rk3308bs

cat >/etc/rk3308bs/companion-stack.env <<EOF
COMPANION_USER=$COMPANION_USER
REPOS_ROOT=$REPOS_ROOT
KIAUH_DIR=$REPOS_ROOT/kiauh
MOONRAKER_HOST=$MOONRAKER_HOST
MOONRAKER_PORT=$MOONRAKER_PORT
CROWSNEST_PORT=$CROWSNEST_PORT
EOF

cat >/etc/rk3308bs/companion-stack-readme.txt <<EOF
Companion stack helper staged during image build.

This board is a CLIENT ONLY -- it does not run Klipper or Moonraker locally.
It connects to a separate main printer-control board that runs the real
Klipper + Moonraker instance.

Only KIAUH is pre-staged (at $REPOS_ROOT/kiauh). KIAUH downloads and installs
KlipperScreen and Crowsnest (and, if ever needed, Klipper/Moonraker) itself.

To finish setup (set the remote host IP, seed sample configs, and install
KlipperScreen + Crowsnest via KIAUH), run:

  rk3308bs-setup-companion-stack

(Also referenced in the MOTD until you've run it once.)
EOF

# Chown only KIAUH -- NOT a recursive chown of all of $REPOS_ROOT (the shared
# /opt directory), which would reassign ownership of unrelated /opt content.
[[ -d "$REPOS_ROOT/kiauh" ]] && chown -R "$COMPANION_USER:$COMPANION_USER" "$REPOS_ROOT/kiauh" 2>/dev/null || true

echo "[rk3308bs] Companion stack staged (KIAUH only)"