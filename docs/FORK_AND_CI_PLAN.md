# Fork upstream sources and GitHub CI plan

Companion firmware for Artillery M1 Pro X1 S1-SOC (RK3308BS). This document plans owning the full source stack: forks, patch queues, and automated rebuild on GitHub.

## Current pipeline (today)

```text
[Linux build host]  RELEASE_TAG=<tag> tools/build-from-source-linux.sh
        |  Armbian compile.sh: kernel (patches/*.patch) + board config + userpatches
        |  -> compiled Armbian image (kernel + rootfs) from source
        v
   build-emmc-release.sh -> build-armbian-bootimg.sh (boot.img: kernel + custom DTB + logo)
        |
   tools/pack-firmware-linux.sh (afptool / rkImageMaker, Linux-only)
        v
   releases/<tag>/rk3308bs-1.0.0-<tag>-emmc.img
```

The current line **recompiles the kernel and rootfs from source** (Armbian) and
packs the monolithic Rockchip image with Linux-only tooling. There is no Windows
pack step and no prebuilt "build-artifacts tarball" repatch model anymore.

## Target architecture

```text
                    +------------------+
                    |  This repo       |
                    |  M1-SOC-Armbian  |
                    |  - board DTS     |
                    |  - patches/      |
                    |  - userpatches   |
                    |  - tools/       |
                    |  - GitHub Actions|
                    +--------+---------+
                             |
         +-------------------+-------------------+
         |                   |                   |
         v                   v                   v
 +---------------+   +---------------+   +------------------+
 | fork:         |   | fork:         |   | fork (optional): |
 | armbian/build |   | linux stable  |   | rockchip rkbin   |
 |               |   | v6.18.y       |   | MiniLoader, etc. |
 +---------------+   +---------------+   +------------------+
```

### Repos to fork (under `xateesix` or org)

| Fork | Upstream | Role |
|------|----------|------|
| `M1-SOC-armbian-build` | `github.com/armbian/build` | Image compile framework, `compile.sh`, board hooks |
| `M1-SOC-linux` | `github.com/gregkh/linux` branch `linux-6.18.y` | Kernel + our `patches/*.patch` as commits or quilt series |
| `M1-SOC-Armbian-Build` (existing private) | — | Board integration, from-source pack pipeline, docs, release scripts |
| `M1-SOC-Armbian-Build-scripts-public` (current public) | export of sanitized tree + Releases |

Optional: vendor `factory_fresh` partition templates in this repo or a small `M1-SOC-rk3308-factory` submodule (Rockchip loader binaries are redistributable per vendor terms; document provenance).

## Patch strategy

| Layer | Location today | Fork strategy |
|-------|----------------|---------------|
| Kernel DTS + drivers | `patches/0001-0009`, `dts/` | Apply as git commits on `M1-SOC-linux` or export quilt series synced by CI |
| Armbian board | `rk3308bs-evb.conf`, `userpatches-*` | Pin in `M1-SOC-armbian-build` fork or copy into `userpatches/` on each sync |
| Boot DTB (display, lights) | `tools/patch-dtb-*.py`, `build-armbian-bootimg.sh` | Stay in integration repo; inputs = kernel Image + factory resource |
| Rootfs companion | `userpatches-chroot/*.sh`, `overlay/` | Stay in integration repo; public `m1prox1` / no WiFi |

**Rule:** forks hold **upstream-shaped** changes; integration repo holds **product** scripts (from-source pack, companion docs, release).

## GitHub Actions (proposed)

### Workflow 1: `sync-upstream.yml` (weekly + manual)

- Checkout forks with `actions/checkout`
- Subtree or scripted merge from upstream tags (`armbian` release branch, `linux-6.18.y`)
- Re-apply patch queue (fail PR if conflicts)
- Open auto-PR `upstream-sync-YYYY-MM-DD` for human review

### Workflow 2: `build-artifacts.yml` (self-hosted Linux runner)

**Runner:** same class as `your-host` Ubuntu (label `rk3308-builder`) with cached `armbian-build` tree.

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  armbian-image:
    runs-on: [self-hosted, rk3308-builder]
    steps:
      - checkout integration repo
      - source config.env.public.example
      - RELEASE_TAG=ci-${{ github.sha }} bash tools/build-from-source-linux.sh
      - upload-artifact: rk3308bs-1.0.0-<tag>-emmc.img (or split if >2GB)
```

### Workflow 3: `release.yml` (on tag `v*`)

- Attach the `.img` to a GitHub Release (external mirror if >2 GB)
- Run `tools/push-to-public.sh` for the source-only public snapshot
- **Gate:** manual approval / only after a test flash job passes

### Secrets

| Secret | Use |
|--------|-----|
| `BUILD_SSH_KEY` | self-hosted runner registration |
| `DISCORD_WEBHOOK_URL` | optional build notify (private repo only) |

No WiFi or user passwords in CI — use `config.env.public.example` only.

## Migration phases

### Phase 1 — Now (local)

- [x] `tools/build-from-source-linux.sh` — from-source kernel+rootfs build and Linux-only eMMC pack
- [x] Allow-listed public export (`tools/push-to-public.sh` + `.public-export-allow`)
- [ ] Flash-test image before any Release upload
- [ ] Commit integration scripts + `docs/FORK_AND_CI_PLAN.md`

### Phase 2 — Forks

1. Fork `armbian/build` and `linux` on GitHub
2. Push kernel patches as commits; tag `m1pro-v6.18.1-r1`
3. Document `BRANCH` / `KERNELBRANCH` pins in `config.env.example`
4. Set `FETCH_ARMBIAN_SOURCE=1` / `FETCH_KERNEL_SOURCE=1` to clone forks instead of upstream

### Phase 3 — Self-hosted CI

1. Register Ubuntu builder + Windows pack runner
2. Implement `build-artifacts.yml` + artifact cache
3. Implement companion pack job with RKDevTool v2.86 path

### Phase 4 — Upstream sync automation

1. `sync-upstream.yml` with conflict PRs
2. Optional: Dependabot-style weekly kernel stable tag check

## File size / Release constraints

- Monolithic `.img` is ~6.4 GB — **exceeds GitHub single-asset 2 GB limit**
- Options: self-hosted release mirror, split download, Git LFS + billing, or OCI bucket (S3/R2) with Release linking URL only

Plan: CI uploads tarball to release; `.img` hosted on external mirror until GitHub Large File Storage or chunking is configured.

## Local commands (maintainer)

```bash
# Full from-source build (kernel + rootfs) and eMMC pack
RELEASE_TAG=<tag> bash tools/build-from-source-linux.sh

# Public export (no firmware in git; allow-listed squashed snapshot)
bash tools/push-to-public.sh
```

## Open decisions

1. **Org vs personal forks** — single `xateesix` org for all forks?
2. **Kernel line** — stay on 6.18.y vs track Armbian `current` branch?
3. **Image hosting** — where to put 6 GB `.img` for public users?
4. **Test gate** — manual flash checklist vs automated hardware test runner?