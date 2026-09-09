#!/bin/bash
set -euo pipefail

modprobe rfkill
modprobe libarc4
modprobe cfg80211
modprobe mac80211
modprobe 8189fs
