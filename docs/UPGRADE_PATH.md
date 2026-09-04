# Host + toolhead upgrade and S1-SOC companion role

## Project goal

Make an Artillery M1 Pro X1 that is **barely usable or unusable** on the factory stack into a **current mainline Klipper** printer  -  not by running everything on the old RK3308 board, but with a **split architecture**.

| Role | Hardware | Software |
|------|----------|----------|
| **Motion / Klipper MCU** | New **host + CNC toolhead** | Mainline **Klipper** (heavy lifting) |
| **Display + camera** | Factory **S1-SOC** (RK3308) | **KlipperScreen**, **Crowsnest** |

The S1-SOC is an **external companion node**  -  stock LCD and network for UI and webcam  -  while the new boards control the printer.

**Status:** The S1-SOC companion image is functional (display, WiFi, thermal, touch working; KlipperScreen/Crowsnest staged for install). Remaining work is on the **motion stack**: Z-stop/probe is unfinished.

## Motion stack (required)

| Role | Example hardware |
|------|------------------|
| **Main host** (3 or 4 axis + Klipper MCU) | [BIGTREETECH Manta M4P](https://www.biqu.equipment/products/bigtreetech-manta-m4p) |
| **Toolhead / CNC board** | [FYSETC H36](https://www.fysetc.com/products/fysetc-h36-mainboard) |

This pair runs **Klipper** for motion, heaters, fans, and (once complete) bed probing. The S1-SOC does **not** replace this stack.

## 3D printed parts (required for rebuild)

The motion-stack upgrade needs two **printed brackets** in the repository `models/` directory:

| Part | STEP file | Purpose |
|------|-----------|---------|
| **Manta M4P mounting bracket** | [`M4P_M1Pro_Mounting_bracket.step`](../models/M4P_M1Pro_Mounting_bracket.step) | Mount the BTT Manta M4P inside the M1 Pro chassis |
| **Power supply relocate bracket** | [`M1-PowerSupply-Relocate.step`](../models/M1-PowerSupply-Relocate.step) | Relocate the factory PSU to clear space for the new host |

Print from the STEP source or export STL from your CAD tool before assembly.

## Why FYSETC H36 (example toolhead)

| Factor | Notes |
|--------|--------|
| **Temperature rating** | High-temp tolerance for enclosed / hot chamber use |
| **Fan headers** | Multiple **3-wire PWM** fan outputs (not 4-wire RGB) |
| **Expansion** | Enough headers for required and future hardware |
| **Mechanical fit** | Target **sideways** install inside the front print head cover (validation ongoing) |

## Z-stop / probing (work in progress)

Mainline Klipper on the motion stack still needs a reliable **Z reference**.

- **Sovol Eddy** probe
- **Custom housing** on the **front print head cover**
- Wired through the **Manta M4P + H36** stack (not the S1-SOC companion)

## What this repository is for

**Companion firmware** for the factory S1-SOC board:

- Lean **Armbian** on eMMC
- Built-in **480x272** display for **KlipperScreen** (target)
- Network services for **Crowsnest** (target)
- Talks to the **real Klipper host** (Moonraker on the Manta) over WiFi/LAN

It is **not** the Klipper MCU image for the Manta or H36.


Setup guide: [`COMPANION_SETUP.md`](COMPANION_SETUP.md)  -  KlipperScreen + Crowsnest on the S1-SOC, Moonraker on the Manta.

## If you modify harnesses

Expect **delicate JST repinning**, mains and 24 V exposure, and serious failure modes. See [`WARNING.md`](WARNING.md).