# EXPERIMENTAL FIRMWARE  -  READ BEFORE USE

Experimental firmware for the Artillery M1 Pro S1-SOC (RK3308BS). **Not supported** by Artillery 3D.

## Architecture (read this)

| Board | Role |
|-------|------|
| **Host + toolhead** (e.g. Manta M4P + FYSETC H36) | Main **Klipper MCU**  -  motion, heaters, probe |
| **S1-SOC** (this firmware) | **Companion only**  -  **KlipperScreen** + **Crowsnest** |

You need **both** paths for the full project: upgrade the motion stack **and** flash this companion image on the S1-SOC.

Details: [`UPGRADE_PATH.md`](UPGRADE_PATH.md)

## Skills and risks

- **JST repinning**, high voltage (**mains AC**, **24 V**), fire and equipment damage risk.
- Incorrect work can destroy boards or **cause fire** (including structural fire risk).
- **Void warranty.** **You assume all risk.**

## Hardware

USB-C data cable, USB-TTL serial (FT232RL), Windows PC with RKDevTool. See [`README.md`](README.md).
- **3D printed brackets** for Manta M4P mount and PSU relocate - see [`models/`](../models/) and [`UPGRADE_PATH.md`](UPGRADE_PATH.md).