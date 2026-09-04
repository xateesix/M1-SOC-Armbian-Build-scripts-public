# GitHub Releases

## Firmware image

| Asset | Description |
|-------|-------------|
| `rk3308bs-1.0.0-<release-tag>-emmc.img` | Ready-to-flash monolithic Rockchip eMMC image (RKFW), built from source |

| Account | Username | Password |
|---------|----------|----------|
| Normal user | `m1prox1` | `m1prox1` |
| Root | `root` | `m1prox1` |

WiFi is not pre-configured in the published image. Change passwords after first boot, and configure WiFi with `nmtui` / `nmcli` (NetworkManager). Credentials may be pre-baked only in private builds.

## Building the release image

```bash
bash tools/install-build-deps.sh
RELEASE_TAG=<tag> bash tools/build-from-source-linux.sh
```

Output: `releases/<tag>/rk3308bs-1.0.0-<tag>-emmc.img`

The build compiles the kernel and rootfs from source (Armbian) and packs the monolithic image with Linux tooling (afptool / rkImageMaker); no Windows step is required.