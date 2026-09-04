#!/bin/bash
set +e
echo "=== 1. uname -r ==="
uname -r
echo
echo "=== 2. ls -la /sys/class/backlight/ ==="
ls -la /sys/class/backlight/
echo
echo "=== 3. backlight sysfs ==="
for d in /sys/class/backlight/*/; do
  [ -d "$d" ] || continue
  echo "--- $d ---"
  for f in max_brightness brightness actual_brightness bl_power device; do
    if [ -e "${d}${f}" ]; then
      echo "== ${f} =="
      cat "${d}${f}" 2>/dev/null
    fi
  done
  echo "== ls -la device =="
  ls -la "${d}device"
done
echo
echo "=== 4. cat /sys/kernel/debug/pwm ==="
cat /sys/kernel/debug/pwm 2>&1
echo
echo "=== 5. ls -la /sys/class/pwm/ ==="
ls -la /sys/class/pwm/
echo
echo "=== 6. Device tree live ==="
echo "-- cat /proc/device-tree/backlight/compatible --"
cat /proc/device-tree/backlight/compatible 2>&1
echo
echo "-- ls /proc/device-tree/backlight/ --"
ls /proc/device-tree/backlight/ 2>&1
echo
echo "-- hexdump pwms --"
hexdump -C /proc/device-tree/backlight/pwms 2>&1 | head -3
echo
echo "-- hexdump enable-gpios --"
cat /proc/device-tree/backlight/enable-gpios 2>/dev/null | hexdump -C | head -2
echo
echo "-- PWM nodes under /proc/device-tree --"
for n in pwm pwm@ff180000 pwm@ff180010 pwm@ff180020 pwm0 pwm1 pwm2; do
  path="/proc/device-tree/${n}"
  if [ -e "$path" ] || [ -d "$path" ]; then
    echo "EXISTS: $path"
    if [ -f "${path}/status" ]; then
      printf "  status: "
      cat "${path}/status" 2>/dev/null
      echo
    else
      echo "  status: no status file"
    fi
  else
    echo "MISSING: $path"
  fi
done
echo
echo "=== 7. dmesg grep ==="
dmesg | grep -iE 'pwm|backlight|panel' | tail -30
echo
echo "=== 8. ls /sys/class/leds/ ==="
ls /sys/class/leds/
echo
echo "=== 9. grep bl_power rk3308bs-load-display.sh ==="
if [ -f /usr/local/sbin/rk3308bs-load-display.sh ]; then
    grep bl_power /usr/local/sbin/rk3308bs-load-display.sh 2>&1
else
    echo "/usr/local/sbin/rk3308bs-load-display.sh: not installed"
fi
echo
echo "=== 10. systemctl is-enabled rk3308bs-display-modules.service ==="
systemctl is-enabled rk3308bs-display-modules.service 2>&1
