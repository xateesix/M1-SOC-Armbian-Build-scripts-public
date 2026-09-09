#!/bin/bash
set -euo pipefail

for bl in /sys/class/backlight/*; do
    [ -f "$bl/brightness" ] || continue
    echo 255 > "$bl/brightness" 2>/dev/null || true
    if [ -f "$bl/bl_power" ]; then
        echo 0 > "$bl/bl_power" 2>/dev/null || true
    fi
done
