# A3D M1 Pro X1  -  Armbian eMMC Firmware (RK3308BS)

Experimental from-source Armbian firmware for the Artillery M1 Pro S1-SOC control board (Rockchip **RK3308B-S**, board `rk3308bs-evb-m1soc`).

## Project intent

Turn an **otherwise barely usable or unusable** Artillery M1 Pro X1 into a **current mainline Klipper** printer by splitting roles across **new motion hardware** and the **factory S1-SOC board**.

| Role | Hardware | Target software |
|------|----------|-----------------|
| **Printer / motion (heavy lifting)** | New **host + CNC Mainboard with new toolhead board** (e.g. [BTT Manta M4P](https://www.biqu.equipment/products/bigtreetech-manta-m4p) + [FYSETC H36](https://www.fysetc.com/products/fysetc-h36-mainboard)) | Mainline **Klipper** on the MCU stack  -  motion, heaters, fans, probe |
| **Display + camera node** | Factory **RK3308 S1-SOC** (this firmware) | **KlipperScreen** on the stock LCD, **Crowsnest** for webcam streaming |

The S1-SOC is **not** the printer MCU. It is an **external companion**  -  UI and camera  -  while the new host + toolhead boards run Klipper for the machine.

The companion image is functional: the **480x272 display works** (Linux DRM/VOP + framebuffer console), **WiFi** is managed by NetworkManager, thermal/touch are working, and the **KlipperScreen + Crowsnest** companion stack is staged for install via KIAUH. Remaining work is on the **motion stack** (Z-stop/probe) and finishing KlipperScreen/Crowsnest configuration.

> ## WARNING  -  READ FIRST
>
> - **Experimental**  -  not supported by Artillery 3D; no warranty.
> - **Void warranty**  -  flashing and hardware mods void manufacturer warranty.
> - **Dangerous voltages**  -  mains AC and 24 V DC. Fire and shock risk.
> - **Extra hardware**  -  USB-C **data** cable, USB-TTL serial adapter (FT232RL), Windows PC with RKDevTool, MASKROM recovery access, plus the **host + toolhead upgrade** for printer control.
> - **You assume all risk**  -  authors are not liable for damage or injury.
>
> Full text: [`docs/WARNING.md`](docs/WARNING.md)

> **Hardware upgrade required for printing:** Motion and Klipper MCU duties need a **3/4-axis host** and **toolhead board** (see below). This S1-SOC image is for the **companion display/camera node**. Repinning JST connectors and high-voltage work can **destroy hardware** or **cause fire**. See [`docs/UPGRADE_PATH.md`](docs/UPGRADE_PATH.md).

## Target architecture (read before flash)

### Motion stack (required for Klipper printing)

| Part | Example |
|------|---------|
| **Host** (3 or 4 axis + Klipper MCU) | [BIGTREETECH Manta M4P](https://www.biqu.equipment/products/bigtreetech-manta-m4p) |
| **Toolhead / CNC board** | [FYSETC H36](https://www.fysetc.com/products/fysetc-h36-mainboard) |

This combo does the **heavy lifting**  -  steppers, hotend, bed, probe, and mainline Klipper firmware on the MCU.

**Work in progress:** **Z-stop / Z-probe** still required. Current direction: **Sovol Eddy** in a **custom housing** on the front print head cover. The H36 is chosen for high-temp rating, **3-wire PWM** fan headers, enough GPIO for current and future hardware, and [hopefully] **sideways fit** inside the print head cover.

Details: [`docs/UPGRADE_PATH.md`](docs/UPGRADE_PATH.md).

### 3D printed parts (required for rebuild)

| Part | STEP model |
|------|------------|
| Manta M4P mounting bracket | [`models/M4P_M1Pro_Mounting_bracket.step`](models/M4P_M1Pro_Mounting_bracket.step) |
| Power supply relocate bracket | [`models/M1-PowerSupply-Relocate.step`](models/M1-PowerSupply-Relocate.step) |

Print from the STEP files or export STL in your CAD tool. Details: [`docs/UPGRADE_PATH.md`](docs/UPGRADE_PATH.md).

### S1-SOC companion (this repository)

Flash this repo's image on the **factory S1-SOC** to drive:

- **KlipperScreen** on the built-in **480x272** display
- **Crowsnest** for USB webcam streaming to your Klipper stack

The companion talks to your **real Klipper host** (Moonraker on the Manta side) over the network. It does **not** replace the motion boards.


Configuration guide (KlipperScreen  ->  Moonraker IP, Crowsnest on companion, Mainsail/Fluidd webcam URL): [`docs/COMPANION_SETUP.md`](docs/COMPANION_SETUP.md).

Skilled **JST repinning**, **mains / 24 V** awareness, and acceptance of serious risk are required. See [`docs/WARNING.md`](docs/WARNING.md).

## What this is

Experimental **Armbian eMMC firmware** for the **RK3308BS S1-SOC** on the Artillery M1 Pro X1. It replaces the factory Linux image with a lean OS intended as a **KlipperScreen + Crowsnest companion node**, using the stock display and WiFi.

This repository provides the **companion-board firmware and build pipeline**, not the main Klipper MCU firmware for the Manta/H36 stack.

## Media (in this repository)

| Asset | File |
|-------|------|
| Hardware overview video (~45 MB) | [`Media/VID_20260615_141308204.mp4`](Media/VID_20260615_141308204.mp4) |
| Boot logo source (BMP) | [`Media/boot-logo-artillery.bmp`](Media/boot-logo-artillery.bmp) |

The custom boot logo is compiled into boot assembly by `tools/build-armbian-bootimg.sh`.

Board overview and control-header pin identification (case light bar, RGB JST, +LED-).
## USB-C data cable (required for flash)

MASKROM flashing and RKDevTool need a **data-capable** USB connection from your PC to the control board USB port.

| Need | Detail |
|------|--------|
| **Cable** | Good-quality **USB-C data cable** (USB-C to USB-A or USB-C, matching your PC) |
| **Not sufficient** | Charge-only cables, many cheap phone cables, or long/under-spec cables |
| **Symptom if wrong** | RKDevTool never sees the device, or download fails mid-flash |

Use a cable rated for **data + power**. Short, branded or known data cables are more reliable than generic charge cords. If flash is unstable, try another cable and USB port before changing firmware.

## RKDevTool (required on Windows)

Rockchip firmware flash and the final eMMC **pack** step both use **RKDevTool** on a **Windows PC**. This repository does not bundle RKDevTool.

| Need | Detail |
|------|--------|
| **Tool** | RKDevTool (v2.86 or newer recommended)  -  includes `RKDevTool.exe` for flashing and `bin/AFPTool.exe` + `bin/RKImageMaker.exe` for packing |
| **Driver** | Rockchip USB driver via **DriverAssistant** (install before first flash) |
| **Use** | **Upgrade Firmware** tab with a monolithic `.img` (not balenaEtcher / raw `dd`) |
| **USB cable** | Good-quality **USB-C data cable** (see section above) |
| **Recovery** | Board in **MASKROM** (recovery button / maskrom pads + USB) |

**Download and documentation:**

- **Firefly** (ROC-RK3308-CC / RK3308): [Resource downloads (RKDevTool)](https://en.t-firefly.com/doc/download/53.html)  -  [Burning firmware guide](https://wiki.t-firefly.com/en/ROC-RK3308-CC/burning_firmware.html)
- **Radxa** (Rockchip tools): [RKDevTool documentation](https://docs.radxa.com/en/zero/zero3/low-level-dev/rkdevtool)  -  [Windows tools download](https://dl.radxa.com/tools/windows/) (`RKDevTool_Release_v2.86.zip`, `DriverAssistant`)

After installing, run `RKDevTool.exe` as Administrator. Flash steps: [`FLASH_RKDEVTOOL.md`](FLASH_RKDEVTOOL.md).

## USB serial adapter (recommended)

A **USB to TTL serial adapter** lets you see boot logs and log in when WiFi or the display are not set up.

| Need | Detail |
|------|--------|
| **Adapter** | FTDI **FT232RL** USB-TTL (3.3 V logic)  -  e.g. [DSD TECH SH-U09C](https://www.amazon.com/DSD-TECH-Adapter-FT232RL-Compatible/dp/B07BBPX8B8) |
| **Level** | Set adapter jumper to **3.3V** (RK3308 UART is 3.3 V TTL) |
| **Wiring** | GND  ->  GND, adapter TXD  ->  board RX, adapter RXD  ->  board TX (UART3 header) |
| **Baud** | **1500000** |
| **Console** | **`ttyS3`** at 1500000 baud (older factory notes mention `ttyFIQ0`) |

Use PuTTY, Tera Term, or `picocom` at **1500000 8N1**. FTDI VCP drivers: [ftdichip.com](https://ftdichip.com/drivers/vcp-drivers/).

Full wiring and terminal notes: [`docs/SERIAL_CONSOLE.md`](docs/SERIAL_CONSOLE.md).

## Download and flash (companion image)

Host-role rule: if build and flash are on different machines, upload the image to the flashing machine first and run flash there. Do not run `upgrade_tool` or `rkdeveloptool` on the build machine.

1. Obtain the monolithic eMMC image `rk3308bs-1.0.0-<release-tag>-emmc.img` (from **GitHub Releases** or your own from-source build).
2. Flash with RKDevTool  ->  **Upgrade Firmware** (or `upgrade_tool uf <image>` on Linux)
3. **Change the default password** on first login

| Account | Username | Default password |
|---------|----------|------------------|
| Normal user | `m1prox1` | `m1prox1` |
| Root | `root` | `m1prox1` |

WiFi credentials can be pre-baked at build time (private builds) or configured on first boot with `nmcli` / `nmtui` (NetworkManager).

Release assets: [`docs/RELEASE.md`](docs/RELEASE.md)

## Build from source (GPL / customization)

The firmware is compiled **from source** with Armbian: the board's kernel (with the RK3308BS patch set), rootfs, and the flashable Rockchip eMMC image are all produced by the scripts in this repository.

### Build requirements

| Component | Notes |
|-----------|--------|
| **Linux** (Ubuntu/Debian) | Armbian from-source build + Rockchip packaging (Linux-only tooling) |
| **RKDevTool** or `upgrade_tool` | Flash the resulting image to eMMC |
| **Serial** | USB-TTL adapter (FT232RL, 3.3 V)  -  see section above |

### Steps

```bash
git clone <this-repository-url>
cd <repository-directory>

# Install host build dependencies (first time)
bash tools/install-build-deps.sh

# Build kernel + rootfs from source and pack the flashable eMMC image.
# RELEASE_TAG is mandatory and names the release/output image.
RELEASE_TAG=my-build bash tools/build-from-source-linux.sh
```

Output: `releases/<RELEASE_TAG>/rk3308bs-1.0.0-<RELEASE_TAG>-emmc.img`

To capture a kernel DRM/boot trace for debugging, set `DRM_DEBUG=1` (adds `drm.debug` to the kernel cmdline); production images build with `DRM_DEBUG=0`.

### What the scripts do

| Script | Role |
|--------|------|
| `tools/install-build-deps.sh` | Host packages and tools |
| `tools/fetch-build-sources.sh` | Fetch/verify build inputs (factory templates) |
| `tools/build-from-source-linux.sh` | Canonical build entrypoint (kernel+rootfs+pack) |

## Configuration

| File | Purpose |
|------|---------|
| `config.env.example` | Defaults  -  safe to commit |
| `config.env.public.example` | Public-facing example values |
| `config.env` | **Local only**  -  never commit (holds real credentials/URLs) |

## Feature status

| Feature | Status |
|---------|--------|
| S1-SOC companion image (from-source Armbian, kernel 6.18.x) | Working |
| 480x272 parallel-RGB display + framebuffer console + boot logo | Working |
| Serial `ttyS3` @ 1500000 | Working |
| Thermal / TSADC (RK3308BS linear conversion) | Working |
| Goodix touch (GT911, I2C3) | Working |
| WiFi (RTL8189FS) via **NetworkManager** | Working |
| **KlipperScreen** (companion role) | Staged via KIAUH  -  install on device |
| **Crowsnest** (companion role) | Staged via KIAUH  -  install on device |
| Main Klipper MCU (Manta M4P + H36) | **Required separate upgrade**  -  not this image |
| Z-stop / bed probe (motion stack) | **WIP**  -  Sovol Eddy + custom cover mount |
| Case light bar (+LED-) | Pin identified; driver in progress |
| RGB pebbles (WS2812) | Not supported |
| Factory Makerbase UI | Not included |

GPIO map: [`docs/GPIO_AND_HARDWARE.md`](docs/GPIO_AND_HARDWARE.md)
Boot logo: [`docs/BOOT_LOGO.md`](docs/BOOT_LOGO.md)

The image build stages KIAUH, Klipper, Moonraker, KlipperScreen, and Crowsnest source trees under `/opt` during rootfs customization; run `/usr/local/sbin/rk3308bs-setup-companion-stack.sh` on device to install KlipperScreen/Crowsnest via KIAUH.

## Build pipeline

```text
tools/install-build-deps.sh   ->  host build dependencies

RELEASE_TAG=<tag> bash tools/build-from-source-linux.sh
  |-- Armbian compile.sh          (kernel + rootfs from source, patches/ applied)
  |-- build-emmc-release.sh       (stage pack_input from the compiled image)
  |    |-- build-armbian-bootimg.sh  (boot.img: kernel + custom DTB + resource/logo)
  |-- tools/pack-firmware-linux.sh   (afptool/rkImageMaker -> monolithic RKFW image)
```

Output: `releases/<tag>/rk3308bs-1.0.0-<tag>-emmc.img`

## Repository layout

| Path | Description |
|------|-------------|
| `tools/build-from-source-linux.sh` | Canonical build entrypoint |
| `tools/` | From-source build + Rockchip packaging scripts |
| `patches/` | Kernel and DTS patches (GPL) |
| `config/` | Kernel config fragments |
| `userpatches-chroot/`, `userpatches-kernel/`, `userpatches-boot/` | Armbian build hooks |
| `overlay/` | On-device services + helpers baked into the rootfs |
| `models/` | 3D printed bracket STEP files |
| `docs/` | User documentation |
| `releases/` | Build output (git-ignored) |

## License and disclaimer

GPL-licensed components remain under their respective licenses. Provided as-is for research and self-hosting. Not affiliated with Artillery 3D.

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md).
