# Companion setup: KlipperScreen + Crowsnest on the S1-SOC

The factory **S1-SOC** (this Armbian image) is a **secondary host**. It does **not** run Klipper for printer motion. It runs **KlipperScreen** and **Crowsnest** and talks to the **main Klipper host** (e.g. BTT Manta M4P + FYSETC H36) over the network.

Decouple UI and camera from the main instance: Moonraker stays on the motion stack; the companion only serves display and webcam streams.

**Status:** the image build now stages the companion stack at compile time. The build pulls KIAUH, Klipper, Moonraker, KlipperScreen, and Crowsnest source trees directly into `/opt` (e.g. `/opt/kiauh`, `/opt/klipper`), then seeds a starter `KlipperScreen.conf` and a companion-stack manifest under `/etc/rk3308bs`.

## Prerequisites

| Item | Where |
|------|--------|
| Main Klipper + **Moonraker** running | Motion host (Manta M4P, etc.) |
| Companion image flashed | S1-SOC eMMC (`rk3308bs-1.0.0-<release-tag>-emmc.img`) |
| Same LAN | Both hosts reachable (WiFi or Ethernet) |
| Webcam (for Crowsnest) | USB camera on **companion** or routed as your build requires |

Note the **IP addresses**:

- `<MAIN_HOST_IP>`  -  Manta / Moonraker (example `192.168.1.50`)
- `<COMPANION_IP>`  -  S1-SOC (example `192.168.1.51`)

## Step 1: KlipperScreen on the companion (S1-SOC)

KlipperScreen only needs the **Moonraker API**. Do **not** install a Klipper MCU stack on the S1-SOC for printer control.

The simplest path is the on-device helper, which wires the remote host, fixes `/opt` ownership, refreshes the apt index (so KIAUH's package installs don't hit stale-pool 404s), and launches KIAUH:

```bash
/usr/local/sbin/rk3308bs-setup-companion-stack.sh
```

In KIAUH, choose **Install -> KlipperScreen** (and **Crowsnest**). To re-open KIAUH later, just run `kiauh` (the wrapper refreshes apt automatically).

Manual details, if you prefer to wire it yourself:

1. Review `/etc/rk3308bs/companion-stack.env` on the companion.
2. Install or finish wiring the stack using the staged source trees directly under `/opt` (e.g. `/opt/kiauh`, `/opt/klipper`).
3. Edit KlipperScreen config (seeded into `/etc/skel/.config/KlipperScreen.conf` during build, and commonly copied into `~/.config/KlipperScreen.conf` after first boot).
4. Point at the **main** Moonraker instance:

```ini
[printer M1ProX1]
moonraker_host: <MAIN_HOST_IP>
moonraker_port: 7125
```

5. Restart KlipperScreen. The **480x272** panel on the S1-SOC should show telemetry and controls for the printer on the motion host.

Multi-printer / remote Moonraker patterns: [KlipperScreen documentation](https://github.com/KlipperScreen/KlipperScreen) and guides on controlling multiple printers via Moonraker host settings.

## Step 2: Crowsnest on the companion (S1-SOC)

Crowsnest is an independent streaming server. It can run on the second host with **no Klipper** on that host.

References: [Running crowsnest on an external device (Mainsail Crew #2252)](https://github.com/orgs/mainsail-crew/discussions/2252)

1. Use the staged `crowsnest` source tree directly under `/opt/crowsnest` or install via KIAUH if you prefer its workflow.
2. Edit `/etc/crowsnest.conf` on the **companion**  -  camera device, resolution, and stream port (commonly **8080**).
3. Start or restart Crowsnest and confirm the stream is live:

```text
http://<COMPANION_IP>:8080/webcam/?action=stream
```

## Step 3: Point Mainsail / Fluidd at the companion stream

Your **web UI runs on the main host** (or your usual browser target). Add the companion camera as an **external** webcam URL.

1. Open **Mainsail** or **Fluidd** (connected to Moonraker on `<MAIN_HOST_IP>`).
2. **Settings**  ->  **Webcams**  ->  add camera.
3. Stream URL:

```text
http://<COMPANION_IP>:8080/webcam/?action=stream
```

4. Save and refresh the dashboard.

The motion host serves Klipper/Moonraker; the companion serves video. Same pattern as multi-camera setups with a separate streaming device.

## Summary

```text
  [ Manta M4P + H36 ]          LAN          [ S1-SOC companion ]
  Klipper + Moonraker  <----------------->  KlipperScreen  ->  Moonraker API
       :7125                                  Crowsnest     ->  :8080 stream
       Mainsail/Fluidd  ----browser---->  webcam URL = COMPANION_IP:8080
```

## Related docs

- [`UPGRADE_PATH.md`](UPGRADE_PATH.md)  -  motion stack (Manta + H36)
- [`README.md`](README.md)  -  project overview
- [`SERIAL_CONSOLE.md`](SERIAL_CONSOLE.md)  -  debug without display/WiFi