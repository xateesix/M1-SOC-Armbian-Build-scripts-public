# Configure and build

Companion image for the S1-SOC (KlipperScreen + Crowsnest). Motion Klipper runs on a separate host (Manta/H36).

The image is compiled **from source** with Armbian: the board kernel (with the RK3308BS patch set in `patches/`), the rootfs, and the flashable Rockchip eMMC image are all produced by the build. The build also bakes in the custom boot logo and stages companion software source trees (KIAUH, Klipper, Moonraker, KlipperScreen, Crowsnest) under `/opt` (e.g. `/opt/kiauh`, `/opt/klipper`).

```bash
# First time: install host build dependencies
bash tools/install-build-deps.sh

# Build from source and pack the eMMC image. RELEASE_TAG is mandatory.
RELEASE_TAG=my-build bash tools/build-from-source-linux.sh
```

Output: `releases/<RELEASE_TAG>/rk3308bs-1.0.0-<RELEASE_TAG>-emmc.img`

Optional build variables:

| Variable | Default | Effect |
|----------|---------|--------|
| `RELEASE_TAG` | (required) | Names the release directory and output image |
| `DRM_DEBUG` | `0` | `1` adds `drm.debug` to the kernel cmdline for display tracing |
| `EXTRA_BOOTARGS` | (empty) | Extra kernel cmdline tokens appended to the DTB bootargs |

After flash, see [`COMPANION_SETUP.md`](COMPANION_SETUP.md) for Moonraker/Crowsnest wiring.

See [`README.md`](../README.md) and [`FLASH_RKDEVTOOL.md`](../FLASH_RKDEVTOOL.md).