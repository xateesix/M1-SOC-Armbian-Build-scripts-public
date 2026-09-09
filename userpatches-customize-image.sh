#!/bin/bash
# Copied to userpatches/customize-image.sh during build-enhanced.sh setup.
# Runs inside Armbian chroot after rootfs is populated.
# Armbian has already mounted /tmp/overlay before calling this script.

set -euo pipefail

# Armbian's own chroot_sdcard() (lib/functions/logging/runners.sh) explicitly sets
# TMPDIR="" on the host-side shell that invokes `chroot`, and that empty value is
# inherited into this script's process tree since chroot doesn't clear the
# environment. An empty (not unset) TMPDIR confuses apt-get/apt-key's temp-file
# creation ("Couldn't create temporary file /tmp/apt.conf.XXXXXX" / "repository is
# not signed"), which -- combined with `set -euo pipefail` in the per-hook scripts
# below -- aborted 20-rk3308bs-hardware.sh and 35-rk3308bs-companion-stack.sh (and
# everything after the failed apt-get call in each) on every build once
# customize_image() actually started being invoked (see the "actually invoke
# customize_image()" fix commit for why it wasn't invoked at all before that).
# Explicitly re-assert a sane TMPDIR before running anything that shells out.
export TMPDIR=/tmp

function rk3308bs_customize_rootfs() {
    # At this point, we're already inside the chroot (${SDCARD}).
    # /tmp/overlay is available as Armbian has mounted it for us.

    # Persist the APT sandbox-user workaround as a real apt.conf.d file (not just a
    # one-off CLI flag on our own apt-get calls, see 20-rk3308bs-hardware.sh). Armbian's
    # own chroot_sdcard() sets TMPDIR="" (empty, not unset) fresh on EVERY separate
    # chroot invocation it makes -- including its OWN later apt-get update call in
    # post_repo_apt_update(), which runs AFTER this hook and has no knowledge of the
    # `export TMPDIR=/tmp` above (that only lives for this script's own process tree).
    # An empty TMPDIR makes apt-key try to create its temp file at "/apt.conf.XXXXXX"
    # (filesystem root), which the sandboxed, non-root "_apt" user cannot write --
    # "Couldn't create temporary file ... for passing config to apt-key". Confirmed via
    # a real build failing at post_repo_apt_update() -> chroot_sdcard_apt_get_update()
    # with exactly this error, for every configured repo, immediately after this hook's
    # own (unaffected, because of the CLI flag) apt-get calls had already succeeded.
    # A persisted apt.conf.d snippet is read by every subsequent apt/apt-key invocation
    # regardless of which script or process calls it, closing the gap for good.
    mkdir -p /etc/apt/apt.conf.d
    echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99rk3308bs-apt-sandbox-fix

    local overlay_root="${OVERLAY_ROOT:-/tmp/overlay}"
    local overlay_scripts=(
        "/usr/local/sbin/rk3308bs-validation.sh"
        "/usr/local/sbin/rk3308bs-diagnose.sh"
    )

    # Step 1: Copy overlay files to rootfs (system config, diagnostics, services)
    if [[ -d "$overlay_root" ]]; then
        echo "[rk3308bs] Applying overlay files to rootfs from $overlay_root..."
        cp -av "$overlay_root"/* / 2>/dev/null || true
        chmod -R +x /usr/local/sbin/ /tmp/rk3308bs-config/ 2>/dev/null || true
    fi

    # Step 2: Ensure the board validation and diagnosis tools are present in the rootfs.
    # Some older/custom builds skip the overlay bind-mount or copy only the top-level files.
    for script in "${overlay_scripts[@]}"; do
        local host_path="${overlay_root}${script}"
        if [[ -f "$host_path" ]]; then
            mkdir -p "$(dirname "$script")"
            cp -f "$host_path" "$script"
            chmod 0755 "$script"
            echo "[rk3308bs] Installed rootfs script: $script"
        fi
    done

    # Step 2b: Ensure display/WiFi loader helpers are present and enabled.
    mkdir -p /usr/local/sbin /etc/systemd/system
    if [[ -f "$overlay_root/usr/local/sbin/rk3308bs-load-wifi.sh" ]]; then
        cp -f "$overlay_root/usr/local/sbin/rk3308bs-load-wifi.sh" /usr/local/sbin/rk3308bs-load-wifi.sh
        chmod 0755 /usr/local/sbin/rk3308bs-load-wifi.sh
    fi
    if [[ -f "$overlay_root/usr/local/sbin/rk3308bs-load-display.sh" ]]; then
        cp -f "$overlay_root/usr/local/sbin/rk3308bs-load-display.sh" /usr/local/sbin/rk3308bs-load-display.sh
        chmod 0755 /usr/local/sbin/rk3308bs-load-display.sh
    fi
    if [[ -f "$overlay_root/etc/systemd/system/rk3308bs-wifi-modules.service" ]]; then
        cp -f "$overlay_root/etc/systemd/system/rk3308bs-wifi-modules.service" /etc/systemd/system/rk3308bs-wifi-modules.service
        systemctl enable rk3308bs-wifi-modules.service 2>/dev/null || true
    fi
    if [[ -f "$overlay_root/etc/systemd/system/rk3308bs-display-modules.service" ]]; then
        cp -f "$overlay_root/etc/systemd/system/rk3308bs-display-modules.service" /etc/systemd/system/rk3308bs-display-modules.service
        systemctl enable rk3308bs-display-modules.service 2>/dev/null || true
    fi

    # Step 3: Run customization scripts from overlay
    for script in \
        /tmp/rk3308bs-config/20-rk3308bs-hardware.sh \
        /tmp/rk3308bs-config/25-rk3308bs-emmc-layout.sh \
        /tmp/rk3308bs-config/30-rk3308bs-preconfigure.sh \
        /tmp/rk3308bs-config/35-rk3308bs-companion-stack.sh
    do
        if [[ -f "$script" ]]; then
            echo "[rk3308bs] Running: $(basename "$script")"
            bash "$script" || echo "[rk3308bs] Warning: $(basename "$script") returned non-zero, continuing..."
        fi
    done
}

function customize_image() {
    echo "[rk3308bs] === Starting RK3308BS Image Customization ==="
    echo "[rk3308bs] System: $(uname -s) $(uname -r)"
    echo "[rk3308bs] Rootfs: ${SDCARD:-/}"
    
    rk3308bs_customize_rootfs
    
    echo "[rk3308bs] === Customization Complete ==="
}

# CRITICAL: Armbian does NOT source this file and call a function by convention --
# lib/functions/rootfs/customize.sh copies it into the chroot as /tmp/customize-image.sh
# and directly EXECUTES it as a script (`chroot_sdcard /tmp/customize-image.sh "$RELEASE"
# "$LINUXFAMILY" "$BOARD" "$BUILD_DESKTOP" "$ARCH"`). Without this top-level call, the
# customize_image() function above is defined but NEVER INVOKED, and the entire body
# silently does nothing (confirmed via build logs: "Section 'customize_image' took 0s
# to execute", zero "[rk3308bs]" log lines anywhere in a full build log). This call was
# missing since this file's creation -- checked full git history, it never existed.
# Real-world impact discovered 2026-08-31 while validating v88: apt-get packages
# (i2c-tools, evtest, libinput-tools, firmware-realtek, wireless-tools, rfkill,
# ca-certificates) were NEVER installed by any build, and the live-tested netplan
# OVS-warning-suppression patch never actually made it into any shipped image -- both
# looked "fixed" only because netplan.io/wpasupplicant/wifi/thermal fixes independently
# ship via Armbian's base image or via pack-armbian-for-emmc.sh's direct final-mount
# writes (a completely separate mechanism, see install_board_runtime_scripts() and the
# goodix firmware blob write in that script), not via this hook at all.
customize_image "$@"
