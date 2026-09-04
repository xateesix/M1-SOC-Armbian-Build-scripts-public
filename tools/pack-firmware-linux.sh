#!/usr/bin/env bash
# Build Rockchip monolithic firmware using official Linux tools.
#
# This replaces the old custom "flat RKFW" writer that produced invalid images
# (upgrade_tool segfault / unbootable flashes).
#
# Usage:
#   tools/pack-firmware-linux.sh <version> [pack_root]
#
# Example:
#   tools/pack-firmware-linux.sh v67-expanded /home/YOUR_USERNAME/pack

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <version> [pack_root]"
    echo "  <version>   release directory under <pack_root>/releases/"
    echo "  [pack_root] defaults to /home/YOUR_USERNAME/scratch/Projects/pack, fallback ~/pack, then <workspace>/pack"
    echo ""
    echo "Optional env:"
    echo "  RKTOOLS_BIN=/path/to/bin   # contains afptool and rkImageMaker"
    echo "  AFPTOOL_RS=/path/to/afptool-rs   # optional fallback binary"
}

need_file() {
    local f="$1"
    [[ -f "$f" ]] || { echo "[ERROR] Missing required file: $f"; exit 1; }
}

resolve_tools_bin() {
    local script_dir workspace_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    workspace_root="$(cd "$script_dir/../.." && pwd)"
    local -a candidates=()

    candidates+=(
        "$workspace_root/tools/vendor/emmc-pack/bin"
    )

    if [[ -n "${RKTOOLS_BIN:-}" ]]; then
        candidates+=("$RKTOOLS_BIN")
    fi

    for d in "${candidates[@]}"; do
        if [[ -f "$d/afptool" && -f "$d/rkImageMaker" && -s "$d/afptool" && -s "$d/rkImageMaker" ]]; then
            chmod +x "$d/afptool" "$d/rkImageMaker" 2>/dev/null || true
            echo "$d"
            return 0
        fi
    done

    echo ""
    return 1
}

resolve_afptool_rs() {
    local script_dir workspace_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    workspace_root="$(cd "$script_dir/../.." && pwd)"
    local -a candidates=()

    if [[ -n "${AFPTOOL_RS:-}" ]]; then
        candidates+=("$AFPTOOL_RS")
    fi

    candidates+=(
        "$workspace_root/tools/vendor/afptool-rs/target/release/afptool-rs"
        "$workspace_root/tools/vendor/afptool-rs/afptool-rs"
    )

    local bin
    for bin in "${candidates[@]}"; do
        if [[ -f "$bin" && -s "$bin" ]]; then
            chmod +x "$bin" 2>/dev/null || true
            echo "$bin"
            return 0
        fi
    done

    echo ""
    return 1
}

validate_output_header() {
    local out_img="$1"
    local first16
    first16="$(dd if="$out_img" bs=1 count=16 2>/dev/null | xxd -p -c 16 || true)"
    [[ "$first16" == 524b4657* ]] || {
        echo "[ERROR] Output does not start with RKFW magic: $out_img"
        exit 1
    }

    # Guardrail: malformed images we've seen had BOOT marker too early in header.
    local first64_hex
    first64_hex="$(dd if="$out_img" bs=1 count=64 2>/dev/null | xxd -p -c 64 || true)"
    if echo "$first64_hex" | grep -qi "424f4f54"; then
        echo "[ERROR] BOOT marker found in first 64 bytes of RKFW header (likely malformed package)."
        exit 1
    fi
}

write_afptool_rs_package_file() {
    local dst="$1"
    cat > "$dst" <<'EOF'
package-file	package-file
bootloader	Image/MiniLoaderAll.bin
parameter	Image/parameter.txt
trust	Image/trust.img
uboot	Image/uboot.img
misc	Image/misc.img
recovery	Image/recovery.img
boot	Image/boot.img
rootfs	Image/rootfs.img
backup	RESERVED
EOF
}

parse_parameter_partitions() {
    local parameter_txt="$1"
    local cmdline partlist item size_hex offset_hex name_raw name

    cmdline="$(grep -E '^CMDLINE:' "$parameter_txt" | sed -E 's/^CMDLINE:[[:space:]]*//')"
    [[ -n "$cmdline" ]] || return 0

    # Extract everything after mtdparts= and split on commas.
    partlist="${cmdline#*mtdparts=:}"
    IFS=',' read -r -a items <<< "$partlist"

    for item in "${items[@]}"; do
        # Expected shape: <size>@<offset>(<name>) where size may be '-'.
        if [[ "$item" =~ ^([^@]+)@([^\(]+)\(([^\)]+)\)$ ]]; then
            size_hex="${BASH_REMATCH[1]}"
            offset_hex="${BASH_REMATCH[2]}"
            name_raw="${BASH_REMATCH[3]}"
            name="${name_raw%%:*}"

            if [[ "$size_hex" == "-" ]]; then
                size_hex="0x00000000"
            fi

            # Emit key=value records for caller to consume.
            echo "$name=$size_hex,$offset_hex"
        fi
    done
}

write_afptool_rs_partition_metadata() {
    local dst="$1"
    local parameter_txt="$2"
    local image_dir="$3"
    declare -A size_by_name=()
    declare -A offset_by_name=()

    while IFS='=' read -r name values; do
        [[ -n "$name" && -n "$values" ]] || continue
        size_by_name["$name"]="${values%%,*}"
        offset_by_name["$name"]="${values##*,}"
    done < <(parse_parameter_partitions "$parameter_txt")

    # Keep bootloader at the standard location used by known-good images.
    size_by_name[bootloader]="${size_by_name[bootloader]:-0x00001000}"
    offset_by_name[bootloader]="${offset_by_name[bootloader]:-0x00002000}"

    # For grow-style rootfs partitions (`-@...`), parameter.txt has no explicit
    # flash_size. upgrade_tool rejects zero, so size it to the actual rootfs.img.
    if [[ "${size_by_name[rootfs]:-0x00000000}" == "0x00000000" && -f "$image_dir/rootfs.img" ]]; then
        local rootfs_bytes rootfs_sectors
        rootfs_bytes="$(stat -c%s "$image_dir/rootfs.img")"
        rootfs_sectors="$(( (rootfs_bytes + 511) / 512 ))"
        size_by_name[rootfs]="$(printf '0x%08x' "$rootfs_sectors")"
    fi

    cat > "$dst" <<EOF
package-file,package-file,0x00000001,0x00000000,0x00000000,0x00000000,0x00000000
bootloader,Image/MiniLoaderAll.bin,${size_by_name[bootloader]:-0x00000000},${offset_by_name[bootloader]:-0x00000000},0x00000000,0x00000000,0x00000000
parameter,Image/parameter.txt,${size_by_name[parameter]:-0x00000000},${offset_by_name[parameter]:-0x00000000},0x00000000,0x00000000,0x00000000
trust,Image/trust.img,${size_by_name[trust]:-0x00000000},${offset_by_name[trust]:-0x00000000},0x00000000,0x00000000,0x00000000
uboot,Image/uboot.img,${size_by_name[uboot]:-0x00000000},${offset_by_name[uboot]:-0x00000000},0x00000000,0x00000000,0x00000000
misc,Image/misc.img,${size_by_name[misc]:-0x00000000},${offset_by_name[misc]:-0x00000000},0x00000000,0x00000000,0x00000000
recovery,Image/recovery.img,${size_by_name[recovery]:-0x00000000},${offset_by_name[recovery]:-0x00000000},0x00000000,0x00000000,0x00000000
boot,Image/boot.img,${size_by_name[boot]:-0x00000000},${offset_by_name[boot]:-0x00000000},0x00000000,0x00000000,0x00000000
rootfs,Image/rootfs.img,${size_by_name[rootfs]:-0x00000000},${offset_by_name[rootfs]:-0x00000000},0x00000000,0x00000000,0x00000000
EOF
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    local version="$1"
    local script_dir workspace_dir pack_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    workspace_dir="$(cd "$script_dir/../.." && pwd)"

    if [[ $# -ge 2 ]]; then
        pack_root="$(cd "$2" && pwd)"
    else
        if [[ -d "/home/YOUR_USERNAME/scratch/Projects/pack" ]]; then
            pack_root="/home/YOUR_USERNAME/scratch/Projects/pack"
        elif [[ -d "$HOME/pack" ]]; then
            pack_root="$HOME/pack"
        else
            pack_root="$workspace_dir/pack"
        fi
    fi

    local target_dir staging_dir image_dir out_img firmware_img tools_bin afptool_rs
    target_dir="$pack_root/releases/$version"
    staging_dir="$target_dir/pack_input"
    image_dir="$staging_dir/Image"
    out_img="$target_dir/rk3308bs-1.0.0-${version}-emmc.img"
    firmware_img="$target_dir/firmware.img"

    echo "=== Rockchip Linux Monolithic Packer ==="
    echo "Pack root:   $pack_root"
    echo "Target dir:  $target_dir"
    echo "Staging dir: $staging_dir"
    echo "Output img:  $out_img"

    [[ -d "$staging_dir" ]] || { echo "[ERROR] Missing staging dir: $staging_dir"; exit 1; }
    [[ -d "$image_dir" ]] || { echo "[ERROR] Missing image dir: $image_dir"; exit 1; }

    need_file "$staging_dir/package-file"
    need_file "$image_dir/MiniLoaderAll.bin"
    need_file "$image_dir/parameter.txt"
    need_file "$image_dir/uboot.img"
    need_file "$image_dir/trust.img"
    need_file "$image_dir/misc.img"
    need_file "$image_dir/recovery.img"
    need_file "$image_dir/boot.img"
    need_file "$image_dir/rootfs.img"

    tools_bin="$(resolve_tools_bin || true)"
    afptool_rs="$(resolve_afptool_rs || true)"
    if [[ -z "$tools_bin" && -z "$afptool_rs" ]]; then
        echo "[ERROR] No usable Linux packer found."
        echo "        Option A (preferred): workspace-local legacy tools at"
        echo "        $workspace_dir/tools/vendor/emmc-pack/bin"
        echo "        with non-empty files: afptool, rkImageMaker"
        echo "        Option B (fallback): workspace-local afptool-rs binary at"
        echo "        $workspace_dir/tools/vendor/afptool-rs/target/release/afptool-rs"
        echo "        Or set RKTOOLS_BIN / AFPTOOL_RS to workspace-local paths."
        exit 1
    fi

    if [[ -n "$tools_bin" ]]; then
        echo "Tools:       $tools_bin"
    else
        echo "Tools:       afptool-rs fallback ($afptool_rs)"
    fi
    mkdir -p "$target_dir"
    rm -f "$firmware_img" "$out_img"

    if [[ -n "$tools_bin" ]]; then
        pushd "$staging_dir" >/dev/null
        "$tools_bin/afptool" -pack . "$firmware_img"
        "$tools_bin/rkImageMaker" -RK3308 "$image_dir/MiniLoaderAll.bin" "$firmware_img" "$out_img" -os_type:androidos
        popd >/dev/null
    else
        local tmpdir rkaf_in rkfw_in update_img
        tmpdir="$(mktemp -d)"
        rkaf_in="$tmpdir/rkaf-input"
        rkfw_in="$tmpdir/rkfw-input"
        update_img="$tmpdir/embedded-update.img"

        mkdir -p "$rkaf_in" "$rkfw_in"
        cp -a "$staging_dir/." "$rkaf_in/"

        # afptool-rs requires UTF-8 package-file and partition-metadata for RKAF packing.
        write_afptool_rs_package_file "$rkaf_in/package-file"
        write_afptool_rs_partition_metadata "$rkaf_in/partition-metadata.txt" "$image_dir/parameter.txt" "$image_dir"

        "$afptool_rs" pack-rkaf "$rkaf_in" "$update_img" --model RK3308 --manufacturer RK3308

        cp "$image_dir/MiniLoaderAll.bin" "$rkfw_in/BOOT"
        cp "$update_img" "$rkfw_in/embedded-update.img"

        "$afptool_rs" pack-rkfw "$rkfw_in" "$out_img" --chip RK3308 --version 8.1.0 --timestamp "$(date +%s)" --code 0x01060007

        rm -rf "$tmpdir"
    fi

    need_file "$out_img"
    validate_output_header "$out_img"

    echo ""
    echo "[SUCCESS] Built flashable monolithic image:"
    ls -lh "$out_img"
    echo "Header:"
    dd if="$out_img" bs=1 count=64 2>/dev/null | xxd -g1
}

main "$@"
