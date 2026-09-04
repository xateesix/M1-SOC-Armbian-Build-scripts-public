# Changelog

## Unreleased (2026-09)
- **Display working**: fixed the RK3308 DRM/VOP bring-up. Restored the
  pre-enable-before-CRTC modeset order (patch 0012) and guarded the NULL
  optional panel regulator that Oops'd at the first modeset (patch 0013).
  The 480x272 panel now lights up with a Linux framebuffer console.
- **VOP resets**: inject CRU resets (axi/ahb/dclk) into the VOP node so
  `rockchip-drm` binds on kernel 6.18.x.
- **Networking**: migrated WiFi from netplan/systemd-networkd to
  **NetworkManager** (required by KlipperScreen); WiFi credentials seeded
  as an NM keyfile connection profile.
- **Companion stack**: fix `/opt` ownership for KIAUH and refresh the apt
  index before KIAUH installs so KlipperScreen/Crowsnest dependencies no
  longer fail on stale-pool 404s.
- **Build tooling**: single canonical from-source build entrypoint
  (`tools/build-from-source-linux.sh`); mandatory `RELEASE_TAG`;
  `EXTRA_BOOTARGS`/`DRM_DEBUG` diagnostic hook.
- **Board rename**: `rk3308bs-evb-m1soc` promoted to a real, in-tree
  kernel DTS build artifact.

## v0.64.1 (2026-06-16)
- Fix m1prox1 home ownership; remove legacy xateesix home/group
- Disable systemd ANSI on framebuffer boot console (tty0)
- Plain-text MOTD branding
- Credential bake: subuid/subgid, home chown, WiFi scrub

## v0.64.1 (2026-06-15)
- Public release: interactive configure.sh, documentation, GPIO hardware map
- Case light bar pin GPIO2_B3 confirmed; RGB deferred
- eMMC pipeline build-release-v64.sh
