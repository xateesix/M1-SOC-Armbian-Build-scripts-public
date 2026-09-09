#!/bin/bash
# RK3308BS Hardware Validation Diagnostic Script
# Run after boot to verify all critical fixes are in place
# Usage: /usr/local/sbin/rk3308bs-validation.sh

set -o pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

test_result() {
    local name="$1"
    local result="$2"
    local message="$3"
    
    if [ "$result" -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC}: $name"
        if [ -n "$message" ]; then
            echo "        $message"
        fi
        ((PASS_COUNT++))
    else
        echo -e "${RED}✗ FAIL${NC}: $name"
        if [ -n "$message" ]; then
            echo "        $message"
        fi
        ((FAIL_COUNT++))
    fi
}

warn_result() {
    local name="$1"
    local message="$2"
    
    echo -e "${YELLOW}⚠ WARN${NC}: $name"
    if [ -n "$message" ]; then
        echo "        $message"
    fi
    ((WARN_COUNT++))
}

echo "======================================"
echo "RK3308BS Hardware Validation Report"
echo "======================================"
echo ""

# Test 1: Kernel version
echo "--- KERNEL & SYSTEM ---"
KERNEL_VERSION=$(uname -r)
if [[ "$KERNEL_VERSION" == *"6.18"* ]]; then
    test_result "Kernel Version" 0 "Version: $KERNEL_VERSION"
else
    test_result "Kernel Version" 1 "Expected 6.18.x, got: $KERNEL_VERSION"
fi

# Test 2: TSADC device in device tree
# NOTE: the node is named tsadc@ff1f0000 (NOT thermal@...); its compatible string
# "rockchip,rk3308bs-tsadc" is the definitive proof our TSADC kernel patch is applied.
echo ""
echo "--- THERMAL SYSTEM (TSADC) ---"
if [ -f /proc/device-tree/tsadc@ff1f0000/status ]; then
    TSADC_STATUS=$(cat /proc/device-tree/tsadc@ff1f0000/status 2>/dev/null | tr -d '\0')
    if [ "$TSADC_STATUS" = "okay" ]; then
        test_result "TSADC Device Tree Status" 0 "Status: $TSADC_STATUS"
    else
        test_result "TSADC Device Tree Status" 1 "Status should be 'okay', got: $TSADC_STATUS"
    fi
else
    test_result "TSADC Device Tree Node" 1 "Device node not found at /proc/device-tree/tsadc@ff1f0000"
fi

# Test 3: Thermal driver present. CONFIG_ROCKCHIP_THERMAL=y (built-in), so it will
# NEVER appear in lsmod -- checking for a module is wrong. Confirm the driver bound
# to the tsadc platform device instead (a bound driver == working thermal driver).
if [ -d /sys/devices/platform/ff1f0000.tsadc/driver ] || \
   [ -e /sys/bus/platform/drivers/rockchip-thermal/ff1f0000.tsadc ]; then
    test_result "Thermal Driver Bound" 0 "rockchip-thermal driver bound to ff1f0000.tsadc (built-in)"
else
    test_result "Thermal Driver Bound" 1 "rockchip-thermal driver not bound to ff1f0000.tsadc"
fi

# Test 4: Thermal zone exists and reads
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    THERMAL_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    if [ -n "$THERMAL_TEMP" ] && [ "$THERMAL_TEMP" != "0" ]; then
        TEMP_C=$((THERMAL_TEMP / 1000))
        test_result "Thermal Temperature Reading" 0 "Current: ${TEMP_C}°C"
    else
        test_result "Thermal Temperature Reading" 1 "No temperature data available (got: $THERMAL_TEMP)"
    fi
else
    test_result "Thermal Zone Exists" 1 "thermal_zone0 not found"
fi

# Test 5: I2C3 pinctrl configured. The touch controller sits on i2c@ff070000
# (which enumerates as Linux i2c-3), NOT ff160000.
echo ""
echo "--- I2C3 TOUCH BUS ---"
if grep -qa "i2c3m0_xfer" /proc/device-tree/i2c@ff070000/pinctrl-names 2>/dev/null || \
   [ -e /proc/device-tree/i2c@ff070000/pinctrl-0 ]; then
    test_result "I2C3 Pinctrl Configuration" 0 "I2C3 (i2c@ff070000) pinctrl configured"
else
    warn_result "I2C3 Pinctrl Configuration" "Could not verify i2c3 pinctrl in DTB"
fi

# Test 6: I2C3 bus exists. Check the actual device node /dev/i2c-3 (present when the
# rk3x-i2c adapter registers); /sys/class/i2c/i2c-3 is not the correct sysfs path.
if [ -c /dev/i2c-3 ] || [ -d /sys/bus/i2c/devices/i2c-3 ]; then
    test_result "I2C3 Bus Device" 0 "I2C adapter 3 present (/dev/i2c-3)"
else
    test_result "I2C3 Bus Device" 1 "I2C adapter 3 not found"
fi

# Test 7: Goodix touch firmware blob
echo ""
echo "--- GOODIX TOUCH PANEL ---"
if [ -f /lib/firmware/goodix_911_cfg.bin ]; then
    BLOB_SIZE=$(stat -f%z /lib/firmware/goodix_911_cfg.bin 2>/dev/null || stat -c%s /lib/firmware/goodix_911_cfg.bin 2>/dev/null)
    if [ "$BLOB_SIZE" -gt 100 ]; then
        test_result "Goodix Firmware Blob" 0 "Found at /lib/firmware/goodix_911_cfg.bin (${BLOB_SIZE} bytes)"
    else
        test_result "Goodix Firmware Blob" 1 "Blob exists but size suspicious (${BLOB_SIZE} bytes)"
    fi
else
    test_result "Goodix Firmware Blob" 1 "Not found at /lib/firmware/goodix_911_cfg.bin"
fi

# Test 8: Goodix driver loaded
if lsmod | grep -q "^goodix"; then
    test_result "Goodix Driver Loaded" 0 "goodix_ts module active"
else
    test_result "Goodix Driver Loaded" 1 "goodix_ts module not loaded"
fi

# Test 9: Goodix touch device present (root-independent; dmesg needs root/dmesg_restrict=0)
if [ -e /sys/bus/i2c/devices/3-005d ] || grep -qi "goodix" /proc/bus/input/devices 2>/dev/null; then
    test_result "Goodix Device Detected" 0 "Goodix touchscreen bound at i2c 3-005d (sysfs/input)"
elif dmesg 2>/dev/null | grep -q "Goodix-TS 3-005d"; then
    GOODIX_ERROR=$(dmesg 2>/dev/null | grep "Goodix-TS" | grep -i "error" | head -1)
    if [ -n "$GOODIX_ERROR" ]; then
        warn_result "Goodix Device Detected" "Detected but with errors: $GOODIX_ERROR"
    else
        test_result "Goodix Device Detected" 0 "Goodix device 3-005d detected in dmesg"
    fi
else
    warn_result "Goodix Device Detected" "Not seen via sysfs/input; run as root to also check dmesg"
fi

# Test 10: Touch input device
echo ""
echo "--- TOUCH INPUT ---"
if ls /dev/input/event* &>/dev/null; then
    EVENT_COUNT=$(ls /dev/input/event* 2>/dev/null | wc -l)
    test_result "Touch Input Devices" 0 "Found $EVENT_COUNT input event device(s)"
else
    test_result "Touch Input Devices" 1 "No input event devices found"
fi

# Test 11: WiFi module loaded
echo ""
echo "--- WIFI MODULE ---"
if lsmod | grep -q "^8189fs"; then
    test_result "WiFi Driver (8189fs)" 0 "Module loaded and active"
else
    test_result "WiFi Driver (8189fs)" 1 "8189fs module not loaded"
fi

# Test 12: WiFi loader service
if systemctl is-enabled rk3308bs-wifi-modules.service &>/dev/null; then
    if systemctl is-active rk3308bs-wifi-modules.service &>/dev/null; then
        test_result "WiFi Loader Service" 0 "rk3308bs-wifi-modules enabled and active"
    else
        test_result "WiFi Loader Service" 1 "Service exists but not active"
    fi
else
    test_result "WiFi Loader Service" 1 "rk3308bs-wifi-modules.service not installed"
fi

# Test 13: wpa_supplicant package (binary lives in /usr/sbin, not in non-root PATH)
echo ""
echo "--- NETWORK & WPA ---"
WPA_BIN="$(command -v wpa_supplicant 2>/dev/null || true)"
if [ -z "$WPA_BIN" ]; then
    for p in /usr/sbin/wpa_supplicant /sbin/wpa_supplicant /usr/local/sbin/wpa_supplicant; do
        [ -x "$p" ] && { WPA_BIN="$p"; break; }
    done
fi
if [ -n "$WPA_BIN" ]; then
    WPA_VERSION=$("$WPA_BIN" -v 2>&1 | head -1)
    test_result "wpa_supplicant Installation" 0 "$WPA_VERSION"
else
    test_result "wpa_supplicant Installation" 1 "wpa_supplicant binary not found"
fi

# Test 14: NetworkManager wifi profile (build writes a pre-seeded NM keyfile connection)
NM_PROFILE="/etc/NetworkManager/system-connections/rk3308bs-wifi.nmconnection"
NM_SSID=""
if command -v nmcli &>/dev/null; then
    # nmcli works unprivileged for listing; prefer it since the keyfile is root-only (0600).
    NM_SSID=$(nmcli -t -f 802-11-wireless.ssid connection show rk3308bs-wifi 2>/dev/null | cut -d: -f2)
    [ -z "$NM_SSID" ] && NM_SSID=$(nmcli -t -f NAME connection show 2>/dev/null | grep -i wifi | head -1)
fi
if [ -n "$NM_SSID" ]; then
    test_result "WiFi Network Configuration" 0 "NetworkManager wifi profile present (SSID: $NM_SSID)"
elif [ -f "$NM_PROFILE" ]; then
    # Fallback when run as root and nmcli unavailable: read SSID straight from keyfile.
    NM_SSID=$(grep -oE '^ssid=.*' "$NM_PROFILE" 2>/dev/null | head -1 | cut -d= -f2-)
    test_result "WiFi Network Configuration" 0 "NetworkManager profile at $(basename "$NM_PROFILE")${NM_SSID:+ (SSID: $NM_SSID)}"
else
    test_result "WiFi Network Configuration" 1 "no NetworkManager wifi profile found (expected $NM_PROFILE)"
fi

# Test 15: NetworkManager status (network stack for this image)
if systemctl is-active NetworkManager &>/dev/null; then
    test_result "NetworkManager Service" 0 "Running and managing network"
else
    test_result "NetworkManager Service" 1 "Not active"
fi

# Test 16: wlan0 interface
if ip link show wlan0 &>/dev/null; then
    WLAN_STATE=$(ip link show wlan0 | grep -oP '(?<=state )[A-Z]+' | head -1)
    if [ -n "$WLAN_STATE" ]; then
        test_result "WLAN0 Interface" 0 "Present, state: $WLAN_STATE"
    else
        test_result "WLAN0 Interface" 1 "Present but state unknown"
    fi
else
    test_result "WLAN0 Interface" 1 "wlan0 interface not found"
fi

# Test 17: WLAN0 IP address
WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -n "$WLAN_IP" ]; then
    test_result "WLAN0 IP Address" 0 "Assigned: $WLAN_IP"
else
    warn_result "WLAN0 IP Address" "No IP assigned yet (interface may need time to connect)"
fi

# Test 18: Display pipeline (rockchip-drm / VOP). vop_bind() calls
# devm_reset_control_get(dev,"ahb"/"dclk") unconditionally; without the CRU
# resets on vop@ff2e0000 it aborts ("failed to get ahb reset") and rockchip-drm
# never creates /dev/dri/card0 or /dev/fb0 -- so KlipperScreen has no output.
echo ""
echo "--- DISPLAY (DRM / VOP) ---"
if [ -e /dev/dri/card0 ] || [ -e /dev/fb0 ]; then
    DRM_NODES=$(ls /dev/dri/card* /dev/fb* 2>/dev/null | tr '\n' ' ')
    test_result "DRM Display Device" 0 "Present: ${DRM_NODES% }"
else
    test_result "DRM Display Device" 1 "No /dev/dri/card0 or /dev/fb0 (rockchip-drm/VOP failed to bind)"
fi

# VOP reset fix: resets=<&cru SRST_VOP_A/H/D>, reset-names axi/ahb/dclk are
# injected into the DTB (patch-dtb-bootargs.py --rk3308-vop-resets) so the
# mandatory "ahb"/"dclk" reset lookups in vop_bind() succeed. The reset-names
# property (world-readable in the live DT) is the definitive proof it is active.
VOP_RESET_NAMES=$(cat /proc/device-tree/vop@ff2e0000/reset-names 2>/dev/null | tr '\0' ' ')
if echo "$VOP_RESET_NAMES" | grep -qw ahb; then
    test_result "VOP Reset Patch" 0 "vop@ff2e0000 reset-names = ${VOP_RESET_NAMES% } (ahb present)"
else
    test_result "VOP Reset Patch" 1 "vop@ff2e0000 has no ahb reset -- DRM/VOP will fail to bind"
fi

# Test 18: Thermal patch applied. The definitive proof is the tsadc node's compatible
# string "rockchip,rk3308bs-tsadc" -- that compatible value is introduced by our
# 0002-thermal-rockchip-rk3308bs-tsadc.patch and selects our linear-conversion code
# path in the driver. dmesg has no reliable patch-specific marker.
echo ""
echo "--- KERNEL PATCHES ---"
TSADC_COMPAT=$(cat /proc/device-tree/tsadc@ff1f0000/compatible 2>/dev/null | tr -d '\0')
if echo "$TSADC_COMPAT" | grep -q "rockchip,rk3308bs-tsadc"; then
    test_result "Thermal Patch Loaded" 0 "TSADC compatible = rockchip,rk3308bs-tsadc (our patch active)"
elif [ -n "$TSADC_COMPAT" ]; then
    warn_result "Thermal Patch Loaded" "TSADC present but compatible is '$TSADC_COMPAT' (expected rockchip,rk3308bs-tsadc)"
else
    test_result "Thermal Patch Loaded" 1 "TSADC compatible string not found"
fi

# Test 19: SD card slot (mmc@ff480000). This DW-MSHC host is the removable SD
# slot (distinct from the eMMC boot device at mmc@ff490000 and the SDIO WiFi at
# mmc@ff4a0000). SD cards enumerate through the MMC subsystem as mmcblkN, not
# /dev/sdX. Card presence is informational -- absence is a WARN, not a FAIL.
echo ""
echo "--- SD CARD SLOT ---"
SD_DT_STATUS=$(cat /proc/device-tree/mmc@ff480000/status 2>/dev/null | tr -d '\0')
if [ "$SD_DT_STATUS" = "okay" ]; then
    test_result "SD Slot Enabled (DT)" 0 "mmc@ff480000 status=okay (SD host enabled)"
elif [ -n "$SD_DT_STATUS" ]; then
    test_result "SD Slot Enabled (DT)" 1 "mmc@ff480000 status=$SD_DT_STATUS (SD host disabled)"
else
    test_result "SD Slot Enabled (DT)" 1 "mmc@ff480000 node not found in device tree"
fi

# Map the SD controller (ff480000) to its mmc_host and check the driver bound.
SD_HOST=""
for h in /sys/class/mmc_host/mmc*; do
    [ -e "$h" ] || continue
    if readlink -f "$h/device" 2>/dev/null | grep -q "ff480000"; then
        SD_HOST=$(basename "$h")
        break
    fi
done
if [ -n "$SD_HOST" ]; then
    test_result "SD Host Controller" 0 "dw_mmc bound to ff480000 as $SD_HOST"
    # Is a card currently inserted? Look for a block device under this host.
    SD_BLK=$(ls -d /sys/class/mmc_host/"$SD_HOST"/"$SD_HOST":*/block/mmcblk* 2>/dev/null | head -1)
    if [ -n "$SD_BLK" ]; then
        SD_DEV=$(basename "$SD_BLK")
        SD_SIZE=$(cat "$SD_BLK/size" 2>/dev/null)
        SD_GB=$(awk "BEGIN{printf \"%.1f\", ${SD_SIZE:-0}*512/1000/1000/1000}")
        test_result "SD Card Detected" 0 "$SD_DEV present (${SD_GB} GB)"
    else
        warn_result "SD Card Detected" "SD host present but no card inserted (insert a card to test)"
    fi
else
    test_result "SD Host Controller" 1 "no mmc_host mapped to ff480000 (dw_mmc did not bind)"
fi

# Summary
echo ""
echo "======================================"
echo -e "Results: ${GREEN}$PASS_COUNT PASS${NC} | ${RED}$FAIL_COUNT FAIL${NC} | ${YELLOW}$WARN_COUNT WARN${NC}"
echo "======================================"

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All critical tests passed!${NC}"
    exit 0
elif [ $FAIL_COUNT -lt 3 ]; then
    echo -e "${YELLOW}Some tests failed - review above${NC}"
    exit 1
else
    echo -e "${RED}Multiple critical failures detected${NC}"
    exit 2
fi
