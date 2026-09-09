#!/usr/bin/env bash
# Build a firmware package from source using Linux-only tooling.
#
# This script intentionally avoids the legacy rootfs-v61 patch chain.
# Flow:
#   1) Prepare Armbian userpatches from this repo
#   2) Compile fresh Armbian image from source
#   3) Stage pack_input from the compiled Armbian image
#   4) Pack monolithic RKFW image with Linux afptool + rkImageMaker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
PACK_ROOT="${PACK_ROOT:-/home/YOUR_USERNAME/scratch/Projects/pack}"
ARMBIAN_BUILD_PATH_DEFAULT="/home/YOUR_USERNAME/scratch/Projects/rk3308bs-workspace/M1-SOC-Armbian-Build"
ARMBIAN_BUILD_PATH="${ARMBIAN_BUILD_PATH:-$ARMBIAN_BUILD_PATH_DEFAULT}"
RELEASE_TAG="${RELEASE_TAG:-}"
DIST_RELEASE="${DIST_RELEASE:-bookworm}"
KERNEL_BRANCH="${KERNEL_BRANCH:-current}"
KERNEL_BTF="${KERNEL_BTF:-no}"
# Single source of truth for the Armbian board slug. Used for the compile.sh BOARD=,
# the staged board .conf filename, AND the post-compile image-selection glob. Keeping
# it in ONE place prevents the class of bug where a board rename updates BOARD= but
# leaves a stale slug in the image-selection glob, silently causing the pack step to
# grab an OLD pre-rename image instead of the one just built (happened 2026-09-02:
# rename rk3308bs-m1pro -> rk3308bs-evb-m1soc updated BOARD= but not the glob, so a
# stale 6.18.48 image got packed instead of the freshly-built 6.18.49).
BOARD_SLUG="${BOARD_SLUG:-rk3308bs-evb-m1soc}"
FACTORY_DIR="${FACTORY_DIR:-$PROJECT_ROOT/factory_fresh/03_partitions}"
RKTOOLS_BIN="${RKTOOLS_BIN:-$WORKSPACE_ROOT/tools/vendor/emmc-pack/bin}"
SKIP_COMPILE="${SKIP_COMPILE:-0}"
OVERWRITE_RELEASE="${OVERWRITE_RELEASE:-0}"
RK3308BS_TSADC="${RK3308BS_TSADC:-1}"
GOODIX_FACTORY_DEFAULTS="${GOODIX_FACTORY_DEFAULTS:-0}"
# GT911 touch calibration window (MINX,SIZEX,MINY,SIZEY). Passed through to the
# boot.img DTB patcher; declares the reachable digitizer sub-window so libinput
# stretches touch to the full 480x272 panel. See tools/build-armbian-bootimg.sh.
GOODIX_CALIBRATION="${GOODIX_CALIBRATION:-0,439,34,181}"
DISABLE_THERMAL_CRITICAL="${DISABLE_THERMAL_CRITICAL:-0}"
DISABLE_TSADC="${DISABLE_TSADC:-0}"
PRECONFIGURE_CREDENTIALS="${PRECONFIGURE_CREDENTIALS:-0}"

# Diagnostic kernel bootargs appended to the DTB /chosen/bootargs. Defaults ON
# (drm.debug) while the RK3308 display bring-up is still being validated so
# every build produces a serial trace of the DRM/VOP/panel modeset sequence.
# Flip DRM_DEBUG=0 (or set EXTRA_BOOTARGS="") once the panel is confirmed
# working to ship a quiet production image.
DRM_DEBUG="${DRM_DEBUG:-1}"
if [[ -z "${EXTRA_BOOTARGS:-}" && "$DRM_DEBUG" == "1" ]]; then
    EXTRA_BOOTARGS="drm.debug=0x1e ignore_loglevel"
fi
EXTRA_BOOTARGS="${EXTRA_BOOTARGS:-}"

if [[ "${RK3308BS_TSADC:-1}" == "0" ]]; then
    echo "[WARN] RK3308BS TSADC kernel fix is disabled; this will trigger the thermal reboot loop on a cold RK3308BS board."
    echo "[WARN] Set RK3308BS_TSADC=1 (default) to rebuild with the linear conversion table fix."
fi

CONFIG_FILE=""
CONFIG_CANDIDATES=(
    "$PROJECT_ROOT/config.env"
    "$ARMBIAN_BUILD_PATH/config.env"
    "$WORKSPACE_ROOT/M1-SOC-Armbian-Build/config.env"
)
for candidate in "${CONFIG_CANDIDATES[@]}"; do
    if [[ -f "$candidate" ]]; then
        CONFIG_FILE="$candidate"
        break
    fi
done
# Warn loudly if more than one config.env exists anywhere in the search path: a stale
# duplicate silently shadowing the canonical one (scripts-private/config.env, checked
# first above) previously caused a wrong WiFi password to get baked into several builds
# with no error or warning at all. Fail closed instead of guessing.
_found_candidates=()
for candidate in "${CONFIG_CANDIDATES[@]}"; do
    [[ -f "$candidate" ]] && _found_candidates+=("$candidate")
done
if [[ ${#_found_candidates[@]} -gt 1 ]]; then
    echo "[ERROR] Multiple config.env files found -- refusing to guess which one is authoritative:" >&2
    printf '  %s\n' "${_found_candidates[@]}" >&2
    echo "[ERROR] Keep only $PROJECT_ROOT/config.env and delete/rename the others, then re-run." >&2
    exit 1
fi
if [[ -n "$CONFIG_FILE" ]]; then
    echo "[INFO] Using config.env: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

PATCH_DTS="$PROJECT_ROOT/patches/0001-arm64-dts-rockchip-add-rk3308bs-evb-m1soc.patch"
PATCH_THERMAL="$PROJECT_ROOT/patches/0002-thermal-rockchip-rk3308bs-tsadc.patch"
BOARD_CONF="$PROJECT_ROOT/rk3308bs-evb-m1soc.conf"
CUSTOMIZE_IMAGE="$PROJECT_ROOT/userpatches-customize-image.sh"
HW_CHROOT="$PROJECT_ROOT/userpatches-chroot/20-rk3308bs-hardware.sh"
EMMC_LAYOUT_CHROOT="$PROJECT_ROOT/userpatches-chroot/25-rk3308bs-emmc-layout.sh"
PRECONFIG_CHROOT="$PROJECT_ROOT/userpatches-chroot/30-rk3308bs-preconfigure.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --armbian-build-path PATH   Path to armbian build fork (default: $ARMBIAN_BUILD_PATH_DEFAULT)
  --release-tag TAG           Output release directory tag (REQUIRED -- no default;
                               a stale hardcoded "v64-..." default previously caused a
                               real build to silently produce a misleadingly-versioned
                               image. Pick something reflecting the actual current
                               iteration, e.g. v98-my-fix-description)
  --dist-release NAME         Armbian distro release (default: bookworm)
  --kernel-branch NAME        Armbian kernel branch (default: current)
  --factory-dir PATH          Factory partition bundle dir (default: factory_fresh/03_partitions)
  --rktools-bin PATH          Directory containing afptool + rkImageMaker (default: /home/YOUR_USERNAME/emmc-pack/bin)
  --skip-compile              Skip compile.sh and reuse latest existing Armbian image
  --preconfigure-credentials  Bake user/password/WiFi via config/30 hook (default: disabled)
  --allow-overwrite           Allow reusing an existing release tag directory
  -h, --help                  Show this help

Environment alternatives:
    ARMBIAN_BUILD_PATH, RELEASE_TAG, DIST_RELEASE, KERNEL_BRANCH, FACTORY_DIR, RKTOOLS_BIN,
    SKIP_COMPILE, OVERWRITE_RELEASE, PRECONFIGURE_CREDENTIALS
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --armbian-build-path) ARMBIAN_BUILD_PATH="$2"; shift 2 ;;
        --release-tag) RELEASE_TAG="$2"; shift 2 ;;
        --dist-release) DIST_RELEASE="$2"; shift 2 ;;
        --kernel-branch) KERNEL_BRANCH="$2"; shift 2 ;;
        --factory-dir) FACTORY_DIR="$2"; shift 2 ;;
        --rktools-bin) RKTOOLS_BIN="$2"; shift 2 ;;
        --skip-compile) SKIP_COMPILE=1; shift ;;
        --preconfigure-credentials) PRECONFIGURE_CREDENTIALS=1; shift ;;
        --allow-overwrite) OVERWRITE_RELEASE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$RELEASE_TAG" ]]; then
    echo "[ERROR] --release-tag (or RELEASE_TAG env var) is required -- no default is provided." >&2
    echo "        This used to silently fall back to a stale hardcoded 'v64-from-source-linux'" >&2
    echo "        default, which caused real confusion after v92-v97 were built (see session" >&2
    echo "        history 2026-09-02). Pass an explicit, current tag, e.g.:" >&2
    echo "          --release-tag v98-my-fix-description" >&2
    exit 1
fi

need_file() {
    local file="$1"
    [[ -f "$file" ]] || { echo "[ERROR] Missing file: $file"; exit 1; }
}

need_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "[ERROR] Missing directory: $dir"; exit 1; }
}

need_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $cmd"; exit 1; }
}

need_nonempty_file() {
    local file="$1"
    [[ -f "$file" ]] || { echo "[ERROR] Missing file: $file"; exit 1; }
    [[ -s "$file" ]] || { echo "[ERROR] File is empty: $file"; exit 1; }
}

resolve_factory_dir() {
    local current="$1"
    if [[ -d "$current" ]]; then
        echo "$current"
        return 0
    fi

    local candidate
    candidate="$WORKSPACE_ROOT/M1-SOC-Armbian-Build/factory_fresh/03_partitions"
    if [[ -d "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    echo "$current"
}

ensure_inside_workspace() {
    local input_path="$1"
    local label="$2"
    local resolved

    resolved="$(realpath -m "$input_path")"
    if [[ "$resolved" != "$WORKSPACE_ROOT"* ]]; then
        echo "[ERROR] $label must be inside workspace: $WORKSPACE_ROOT"
        echo "        Current: $resolved"
        exit 1
    fi
}

find_latest_armbian_image() {
    local out_dir="$1"
    local newer_than="${2:-}"   # optional marker file; if set, only images newer than it qualify
    local -a find_args=("$out_dir" -maxdepth 1 -type f)
    # Case-insensitive match on the current board slug -- Armbian capitalizes the board
    # name in the image filename (rk3308bs-evb-m1soc -> Rk3308bs-evb-m1soc), so -iname
    # is used rather than a hardcoded-capitalization glob. Matching $BOARD_SLUG (not a
    # literal) is what prevents the stale-image bug after a board rename.
    local latest

    # Prefer uncompressed .img, then .img.xz. Within each, newest by mtime, and (if a
    # freshness marker was given) only images strictly newer than it.
    local ext
    for ext in img img.xz; do
        if [[ -n "$newer_than" && -e "$newer_than" ]]; then
            latest="$(find "${find_args[@]}" -iname "Armbian-*${BOARD_SLUG}*.${ext}" -newer "$newer_than" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
        else
            latest="$(find "${find_args[@]}" -iname "Armbian-*${BOARD_SLUG}*.${ext}" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
        fi
        if [[ -n "$latest" ]]; then
            echo "$latest"
            return 0
        fi
    done

    return 1
}

install_userpatches() {
    local build_path="$1"
    local yaml_ssid yaml_password
    local kernel_current_dir="$build_path/userpatches/kernel/rockchip64-current"
    local kernel_archive_dir="$build_path/userpatches/kernel/archive/rockchip64-6.18"

    mkdir -p "$build_path/config/boards"
    mkdir -p "$kernel_current_dir"
    mkdir -p "$kernel_archive_dir"
    mkdir -p "$build_path/userpatches/overlay"

    cp "$BOARD_CONF" "$build_path/config/boards/${BOARD_SLUG}.conf"
    sed -i 's/\r$//' "$build_path/config/boards/${BOARD_SLUG}.conf"

    # Take full, authoritative ownership of the kernel patch directories: delete ANY
    # pre-existing *.patch files before staging exactly what's tracked in this repo's
    # patches/ directory. Armbian applies every *.patch file found here in filename
    # order, so an orphaned/stale patch left behind by older or different tooling
    # (e.g. a duplicate DTS patch under a different filename, applied alphabetically
    # AFTER ours) can silently reapply on every build and shadow our fixes without any
    # error or warning. This bit us once already: a July 21/22 leftover
    # "0001-arm64-dts-rockchip-add-rk3308bs-evb-amic-v11.patch" (missing the TSADC
    # compatible-string fix) was still present in this directory and clobbered the
    # freshly-fixed DTS applied just before it. Clearing first makes this directory
    # fully reproducible from patches/ alone.
    find "$kernel_current_dir" -maxdepth 1 -name '*.patch' -type f -delete
    find "$kernel_archive_dir" -maxdepth 1 -name '*.patch' -type f -delete

    shopt -s nullglob
    for patch_file in "$PROJECT_ROOT"/patches/*.patch; do
        cp "$patch_file" "$kernel_current_dir/$(basename "$patch_file")"
        cp "$patch_file" "$kernel_archive_dir/$(basename "$patch_file")"
        sed -i 's/\r$//' "$kernel_current_dir/$(basename "$patch_file")"
        sed -i 's/\r$//' "$kernel_archive_dir/$(basename "$patch_file")"
    done
    shopt -u nullglob


    # NOTE: WiFi credentials are NOT also written here as a static
    # /etc/netplan/01-rk3308bs-wlan0.yaml overlay file. That used to happen
    # (see git history), but was dormant/harmless for every build through v90
    # because the overlay-copy-all step in customize_image() never actually ran
    # (see the "actually invoke customize_image()" fix). Once that hook started
    # genuinely running (v91+), this static file started actually landing in the
    # rootfs alongside armbian-firstlogin's own PRESET_NET_WIFI_*-driven
    # /etc/netplan/30-wifis-dhcp.yaml (the proven, validated WiFi mechanism used
    # all session) -- both defining an access-point for the same SSID, which
    # `netplan apply` then rejects with "Duplicate access point SSID". Removed
    # entirely rather than merged/deduplicated, since firstboot.conf's
    # PRESET_NET_WIFI_SSID/PRESET_NET_WIFI_KEY (below) already carries the exact
    # same WIFI_SSID/WIFI_PASSWORD values through the one mechanism that's
    # actually been tested end-to-end this session.
    #
    # Explicitly remove any stale copy from a previous build too -- this exact
    # file lingered in $build_path/userpatches/overlay/etc/netplan/ from a v92
    # build and got silently re-copied forward into v93 even after the
    # generation code above was removed, since nothing ever cleaned the
    # overlay tree between runs (a "stale artifact" bug class that has bitten
    # this codebase multiple times this session).
    rm -f "$build_path/userpatches/overlay/etc/netplan/01-rk3308bs-wlan0.yaml"

    if [[ -d "$PROJECT_ROOT/overlay" ]]; then
        cp -a "$PROJECT_ROOT/overlay/." "$build_path/userpatches/overlay/"
    fi

    mkdir -p "$build_path/userpatches/overlay/usr/local/sbin" "$build_path/userpatches/overlay/etc/systemd/system"
    cp -f "$PROJECT_ROOT/overlay/usr/local/sbin/rk3308bs-diagnose.sh" "$build_path/userpatches/overlay/usr/local/sbin/rk3308bs-diagnose.sh"
    cp -f "$PROJECT_ROOT/overlay/usr/local/sbin/rk3308bs-validation.sh" "$build_path/userpatches/overlay/usr/local/sbin/rk3308bs-validation.sh"
    chmod 0755 "$build_path/userpatches/overlay/usr/local/sbin/rk3308bs-diagnose.sh" "$build_path/userpatches/overlay/usr/local/sbin/rk3308bs-validation.sh"

    cat > "$build_path/userpatches/firstboot.conf" <<EOF
PRESET_ROOT_PASSWORD="$ROOT_PASSWORD"
PRESET_USER_NAME="${USER_NAME:-m1prox1}"
PRESET_USER_PASSWORD="${USER_PASSWORD:-$ROOT_PASSWORD}"
PRESET_DEFAULT_REALNAME="${USER_REALNAME:-${USER_NAME:-m1prox1}}"
PRESET_LOCALE="${LOCALE:-en_US.UTF-8}"
PRESET_TIMEZONE="${TIMEZONE:-America/Los_Angeles}"
SET_LANG_BASED_ON_LOCATION=n
PRESET_NET_CHANGE_DEFAULTS=1
PRESET_NET_ETHERNET_ENABLED=0
PRESET_NET_WIFI_ENABLED=1
PRESET_NET_WIFI_SSID="${WIFI_SSID:-}"
PRESET_NET_WIFI_KEY="${WIFI_PASSWORD:-}"
PRESET_NET_WIFI_COUNTRYCODE="${WIFI_COUNTRY:-US}"
PRESET_CONNECT_WIRELESS=0
EOF

    if [[ -f "$CUSTOMIZE_IMAGE" ]]; then
        cp "$CUSTOMIZE_IMAGE" "$build_path/userpatches/customize-image.sh"
        chmod +x "$build_path/userpatches/customize-image.sh"
    fi

    COMPANION_CHROOT="$PROJECT_ROOT/userpatches-chroot/35-rk3308bs-companion-stack.sh"

    for hook in "$HW_CHROOT" "$EMMC_LAYOUT_CHROOT" "$COMPANION_CHROOT"; do
        if [[ -f "$hook" ]]; then
            cp "$hook" "$build_path/config/$(basename "$hook")"
            chmod +x "$build_path/config/$(basename "$hook")"
        fi
    done

    # userpatches-customize-image.sh actually executes hooks from /tmp/rk3308bs-config/ (via the
    # overlay bind-mount), NOT from config/ above -- config/ is otherwise unused by our pipeline.
    # The overlay/tmp/rk3308bs-config/*.sh files committed in this repo can silently drift out of
    # sync with the canonical userpatches-chroot/*.sh sources (this happened before: the overlay
    # copy of 20-rk3308bs-hardware.sh was missing display-loader content added later to the
    # canonical file). Always overwrite with the canonical hooks here so the copy that actually
    # runs during customize-image.sh is never stale.
    mkdir -p "$build_path/userpatches/overlay/tmp/rk3308bs-config"
    for hook in "$HW_CHROOT" "$EMMC_LAYOUT_CHROOT" "$COMPANION_CHROOT"; do
        if [[ -f "$hook" ]]; then
            cp -f "$hook" "$build_path/userpatches/overlay/tmp/rk3308bs-config/$(basename "$hook")"
            chmod 0755 "$build_path/userpatches/overlay/tmp/rk3308bs-config/$(basename "$hook")"
        fi
    done

    if [[ "$PRECONFIGURE_CREDENTIALS" == "1" ]]; then
        if [[ -f "$PRECONFIG_CHROOT" ]]; then
            cp "$PRECONFIG_CHROOT" "$build_path/config/$(basename "$PRECONFIG_CHROOT")"
            chmod +x "$build_path/config/$(basename "$PRECONFIG_CHROOT")"
            cp -f "$PRECONFIG_CHROOT" "$build_path/userpatches/overlay/tmp/rk3308bs-config/$(basename "$PRECONFIG_CHROOT")"
            chmod 0755 "$build_path/userpatches/overlay/tmp/rk3308bs-config/$(basename "$PRECONFIG_CHROOT")"
        fi
    else
        rm -f "$build_path/config/$(basename "$PRECONFIG_CHROOT")"
        rm -f "$build_path/userpatches/overlay/tmp/rk3308bs-config/$(basename "$PRECONFIG_CHROOT")"
    fi

    cat > "$build_path/userpatches/config.conf" <<EOF
BOARD=$BOARD_SLUG
BRANCH=$KERNEL_BRANCH
RELEASE=$DIST_RELEASE
BUILD_MINIMAL=yes
EXPERT=yes
PREFER_DOCKER=no
KERNEL_CONFIGURE=no
NO_HOST_RELEASE_CHECK=yes
VENDOR=Armbian-M1Pro
EOF
    ln -sf config.conf "$build_path/userpatches/config-default.conf"
}

apply_active_kernel_patch() {
    local build_path="$1"
    local kernel_dir=""
    local kernel_file=""

    if [[ ! -f "$PATCH_THERMAL" ]]; then
        return 0
    fi

    kernel_dir="$(find "$build_path/cache/sources/linux-kernel-worktree" -mindepth 1 -maxdepth 1 -type d -name '*rockchip64*' 2>/dev/null | head -n 1 || true)"
    if [[ -z "$kernel_dir" ]]; then
        echo "[WARN] No kernel worktree detected under $build_path/cache/sources/linux-kernel-worktree; skipping active-tree patch apply."
        return 0
    fi

    kernel_file="$kernel_dir/drivers/thermal/rockchip_thermal.c"
    if [[ ! -f "$kernel_file" ]]; then
        echo "[WARN] Active kernel worktree not found at $kernel_dir; skipping active-tree patch apply."
        return 0
    fi

    if grep -q 'rockchip,rk3308bs-tsadc' "$kernel_file"; then
        echo "[OK] Active kernel worktree already contains the RK3308BS TSADC patch: $kernel_dir"
        return 0
    fi

    if ! git -C "$kernel_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "[WARN] Active kernel worktree is not a git checkout; skipping active-tree patch apply."
        return 0
    fi

    echo "[1/2] Applying RK3308BS TSADC patch to active kernel worktree: $kernel_dir"
    git -C "$kernel_dir" apply --check "$PATCH_THERMAL"
    git -C "$kernel_dir" apply "$PATCH_THERMAL"
    echo "[OK] Active kernel worktree now includes the RK3308BS TSADC patch."
}

echo "=== Linux-only from-source build ==="
echo "Workspace root:     $WORKSPACE_ROOT"
echo "Project root:       $PROJECT_ROOT"
echo "Armbian build path: $ARMBIAN_BUILD_PATH"
echo "Release tag:        $RELEASE_TAG"
echo "Distro release:     $DIST_RELEASE"
echo "Kernel branch:      $KERNEL_BRANCH"
echo "Kernel BTF:         $KERNEL_BTF"
echo "RK3308BS_TSADC:     $RK3308BS_TSADC"
echo "GOODIX_DEFAULTS:    $GOODIX_FACTORY_DEFAULTS"
echo "GOODIX_CALIBRATION: $GOODIX_CALIBRATION"
echo "THERMAL_CRIT_PATCH: $DISABLE_THERMAL_CRITICAL"
echo "DISABLE_TSADC:      $DISABLE_TSADC"
echo "PRECONFIG_CREDS:    $PRECONFIGURE_CREDENTIALS (default: standard Armbian first-boot flow)"
echo "Factory dir:        $FACTORY_DIR"
echo "RKTOOLS_BIN:        $RKTOOLS_BIN"

FACTORY_DIR="$(resolve_factory_dir "$FACTORY_DIR")"
echo "Resolved factory:   $FACTORY_DIR"

need_dir "$PROJECT_ROOT"
need_dir "$ARMBIAN_BUILD_PATH"
need_file "$ARMBIAN_BUILD_PATH/compile.sh"
need_dir "$FACTORY_DIR"
need_file "$FACTORY_DIR/package-file"
need_file "$FACTORY_DIR/MiniLoaderAll.bin"
need_file "$FACTORY_DIR/parameter.txt"
need_file "$FACTORY_DIR/uboot.img"
need_file "$FACTORY_DIR/trust.img"
need_file "$FACTORY_DIR/misc.img"
need_file "$FACTORY_DIR/recovery.img"

need_file "$BOARD_CONF"
need_file "$PATCH_DTS"
need_file "$CUSTOMIZE_IMAGE"
need_cmd bash
need_cmd git
need_cmd python3
need_cmd sudo
need_cmd xz
need_cmd realpath

ensure_inside_workspace "$PROJECT_ROOT" "PROJECT_ROOT"
ensure_inside_workspace "$ARMBIAN_BUILD_PATH" "ARMBIAN_BUILD_PATH"
ensure_inside_workspace "$FACTORY_DIR" "FACTORY_DIR"
ensure_inside_workspace "$RKTOOLS_BIN" "RKTOOLS_BIN"

echo "[1/5] Installing userpatches into Armbian fork"
install_userpatches "$ARMBIAN_BUILD_PATH"

if [[ -f "$PATCH_THERMAL" ]]; then
    apply_active_kernel_patch "$ARMBIAN_BUILD_PATH"
fi

COMPILE_MARKER=""
if [[ "$SKIP_COMPILE" != "1" ]]; then
    echo "[2/5] Compiling Armbian image from source"
    # Drop a freshness marker immediately before compile.sh so we can later verify the
    # image we pack was actually produced by THIS run, never a stale leftover.
    COMPILE_MARKER="$(mktemp)"
    (
        cd "$ARMBIAN_BUILD_PATH"
        ./compile.sh default \
            BOARD="$BOARD_SLUG" \
            BRANCH="$KERNEL_BRANCH" \
            RELEASE="$DIST_RELEASE" \
            BUILD_MINIMAL=yes \
            EXPERT=yes \
            PREFER_DOCKER=no \
            KERNEL_CONFIGURE=no \
            KERNEL_BTF="$KERNEL_BTF" \
            NO_HOST_RELEASE_CHECK=yes \
            VENDOR=Armbian-M1Pro \
            CI=true
    )

    # Armbian's compile.sh self-elevates via sudo when PREFER_DOCKER=no (required for
    # chroot/debootstrap/mount during kernel+rootfs build) and its own SET_OWNER_TO_UID
    # chown-back only covers userpatches/, logs/, and the .deb output storage -- it never
    # reclaims cache/sources/linux-kernel-worktree, so root-owned kernel build objects
    # (.o/.a/vmlinux, etc.) are left behind there. Reclaim them here in one explicit,
    # narrowly-scoped sudo call so later local operations (git worktree removal, patch
    # re-application, cleanup) never need sudo again.
    KERNEL_WORKTREE_ROOT="$ARMBIAN_BUILD_PATH/cache/sources/linux-kernel-worktree"
    if [[ -d "$KERNEL_WORKTREE_ROOT" ]]; then
        echo "[2b/5] Reclaiming ownership of $KERNEL_WORKTREE_ROOT after root-elevated compile"
        sudo chown -R "$(id -u):$(id -g)" "$KERNEL_WORKTREE_ROOT"
    fi
else
    echo "[2/5] Skipping compile step (--skip-compile)"
fi

OUT_IMAGES_DIR="$ARMBIAN_BUILD_PATH/output/images"
need_dir "$OUT_IMAGES_DIR"

echo "[3/5] Selecting compiled Armbian image"
# When we actually compiled, require the selected image to be NEWER than the pre-compile
# marker -- this makes it impossible to silently pack a stale leftover image (e.g. an
# older-kernel or pre-rename image left in output/images/ from a previous run). When
# --skip-compile is used, fall back to newest-matching (no freshness constraint).
if [[ "$SKIP_COMPILE" != "1" && -n "$COMPILE_MARKER" ]]; then
    ARMBIAN_ARTIFACT="$(find_latest_armbian_image "$OUT_IMAGES_DIR" "$COMPILE_MARKER" || true)"
    rm -f "$COMPILE_MARKER"
    if [[ -z "$ARMBIAN_ARTIFACT" ]]; then
        echo "[ERROR] compile.sh completed but produced no fresh image matching board" >&2
        echo "        '$BOARD_SLUG' newer than this run's start in $OUT_IMAGES_DIR." >&2
        echo "        Refusing to pack a stale/pre-existing image. Check the compile log" >&2
        echo "        above for the actual built image name (board slug must match)." >&2
        exit 1
    fi
else
    ARMBIAN_ARTIFACT="$(find_latest_armbian_image "$OUT_IMAGES_DIR" || true)"
    if [[ -z "$ARMBIAN_ARTIFACT" ]]; then
        echo "[ERROR] Could not find Armbian image for board '$BOARD_SLUG' in $OUT_IMAGES_DIR"
        exit 1
    fi
fi
echo "Using artifact: $ARMBIAN_ARTIFACT"

RELEASE_DIR="$PACK_ROOT/releases/$RELEASE_TAG"
FINAL_IMG_CANDIDATE="$RELEASE_DIR/rk3308bs-1.0.0-${RELEASE_TAG}-emmc.img"
if [[ -d "$RELEASE_DIR" && "$OVERWRITE_RELEASE" != "1" ]]; then
    if compgen -G "$RELEASE_DIR/*.img" >/dev/null || [[ -f "$FINAL_IMG_CANDIDATE" ]]; then
        echo "[ERROR] Release tag already exists and contains image artifacts: $RELEASE_DIR"
        echo "        Pick a new --release-tag (recommended) or pass --allow-overwrite explicitly."
        exit 1
    fi
fi
mkdir -p "$RELEASE_DIR"

ARMBIAN_IMG_PATH="$ARMBIAN_ARTIFACT"
if [[ "$ARMBIAN_ARTIFACT" == *.img.xz ]]; then
    ARMBIAN_IMG_PATH="$RELEASE_DIR/_armbian-source.img"
    echo "Decompressing $ARMBIAN_ARTIFACT -> $ARMBIAN_IMG_PATH"
    xz -dkc "$ARMBIAN_ARTIFACT" > "$ARMBIAN_IMG_PATH"
fi

echo "[4/5] Staging pack_input from compiled Armbian image"
(
    cd "$PROJECT_ROOT"
    RK3308BS_TSADC="$RK3308BS_TSADC" GOODIX_FACTORY_DEFAULTS="$GOODIX_FACTORY_DEFAULTS" GOODIX_CALIBRATION="$GOODIX_CALIBRATION" DISABLE_THERMAL_CRITICAL="$DISABLE_THERMAL_CRITICAL" DISABLE_TSADC="$DISABLE_TSADC" EXTRA_BOOTARGS="$EXTRA_BOOTARGS" bash ./build-emmc-release.sh \
        --armbian "$ARMBIAN_IMG_PATH" \
        --version "$RELEASE_TAG" \
        --factory "$FACTORY_DIR" \
        --pack-only
)

echo "[5/5] Linux-only monolithic packaging"
(
    cd "$PROJECT_ROOT"
    RKTOOLS_BIN="$RKTOOLS_BIN" bash ./tools/pack-firmware-linux.sh "$RELEASE_TAG" "$PACK_ROOT"
)

FINAL_IMG="$PACK_ROOT/releases/$RELEASE_TAG/rk3308bs-1.0.0-${RELEASE_TAG}-emmc.img"
need_file "$FINAL_IMG"

echo ""
echo "[SUCCESS] Linux-only from-source firmware built:"
ls -lh "$FINAL_IMG"
sha256sum "$FINAL_IMG"
echo ""
echo "Flash command:"
echo "  sudo upgrade_tool UF $FINAL_IMG"
