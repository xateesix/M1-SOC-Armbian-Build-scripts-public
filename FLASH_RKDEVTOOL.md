# RK3308BS  -  RKDevTool flash guide (Artillery M1 Pro S1-SOC)

## Host role rule (mandatory)

- Build host and flash host are different roles.
- Never run `upgrade_tool` or `rkdeveloptool` on the build host.
- Always upload firmware image from build host to flash host first, then flash on flash host.

Linux flash-host example (SSH alias `flashpc`):

```bash
IMG="rk3308bs-1.0.0-v64-from-source-linux-emmc.img"
SRC="/home/YOUR_USERNAME/scratch/Projects/rk3308bs-workspace/M1-SOC-Armbian-Build/releases/v64-from-source-linux/$IMG"

rsync --partial --append-verify "$SRC" flashpc:~/rk3308bs-firmware/
ssh flashpc "sha256sum ~/rk3308bs-firmware/$IMG"
ssh flashpc "sudo upgrade_tool uf ~/rk3308bs-firmware/$IMG"
```

## Install RKDevTool (not included in this repo)

Use a **Windows PC**. Download RKDevTool and the Rockchip USB driver from vendor tool pages:

| Source | Links |
|-----|----|
| **Firefly** | [RKDevTool download](https://en.t-firefly.com/doc/download/53.html)  -  [ROC-RK3308-CC burning guide](https://wiki.t-firefly.com/en/ROC-RK3308-CC/burning_firmware.html) |
| **Radxa** | [RKDevTool docs](https://docs.radxa.com/en/zero/zero3/low-level-dev/rkdevtool)  -  [Windows tools](https://dl.radxa.com/tools/windows/) |

Recommended: `RKDevTool_Release_v2.86.zip` plus **DriverAssistant**. Install the driver first, then run `RKDevTool.exe` as Administrator.

## USB cable

Use a **good-quality USB-C data cable** between the PC and the board USB port. Charge-only or poor cables often prevent MASKROM detection or cause failed downloads. Try a short, known data cable and a direct motherboard USB port if RKDevTool does not see the device.

## Use Upgrade Firmware + monolithic `.img`

1. Enter **MASKROM** (recovery button / maskrom pads + USB).
2. Open **RKDevTool**.
3. Tab: **Upgrade Firmware** (second tab).
4. **Firmware:** browse to a single monolithic `.img` file.
   - Do **not** load a custom `config.cfg` with separate partition files.
   - Do **not** use **Advanced  ->  Write by address**.
5. Click **Upgrade** / **Run**.
6. Watch the log  -  you **must** see:
   - `Download Boot Success`
   - `Download IDB Success`
   - `Download Firmware Start` with **`Gpt=1`**
   - `Start to download rootfs, offset=0x...` (multi-minute write for large images)
   - `Download Firmware Success` (ret=0, not `ret=1`)
7. Unplug USB, power cycle.

If **Download Boot** fails to start:

- **Advanced**  ->  **Download Loader**  ->  use `MiniLoaderAll.bin` from your partition templates or factory extract
- Immediately repeat step 5 on **Upgrade Firmware** with the **full** `.img`.

---

## Factory reference image

Known-good monolithic package (use for recovery and as packaging reference):

```
KLP_IMG_ARTILLERY_M1_PRO_S1-SOC_20251126_Beta (1)/KLP_IMG_ARTILLERY_M1_PRO_S1-SOC_20251126_Beta.img
```

Unpacked structure matches our repacks:

| Component | Factory | Our repacks |
|--------|------|-------|
| `boot.bin` (MiniLoader) | 321870 bytes | **identical** |
| `package-file` layout | standard Rockchip | **identical** |
| `parameter.txt` | `TYPE: GPT`, `MAGIC: 0x5041524B` | same format |
| RKImageMaker wrap | `-RK3308` + `-os_type:androidos` | same (`windows-pack-update.ps1`) |

If factory `.img` works on Upgrade but a custom `.img` does not, the problem is **not** the tab  -  check the log for the failure patterns below.

---

## Images

| File | When to use |
|---|-------|
| `KLP_IMG_ARTILLERY_..._Beta.img` | **Recovery**  -  known-good factory |
| `SMOKE_v2_repack_only.img` | Validate repack pipeline (factory contents) |
| `rk3308bs-1.0.0-emmc-fixed.img` | Symlink/copy of **latest built** `-vNN.img` (currently **v43** if v45 not built yet) |
| `rk3308bs-1.0.0-emmc-fixed-v43.img` | **Do not use**  -  rootfs baked with `debugfs set_inode_field`  ->  `bogus i_mode` login loop |
| `rk3308bs-1.0.0-emmc-fixed-v45.img` | **Build this next**  -  safe chroot + `/boot/system.cfg` (no v44 image was ever produced) |
| `rk3308bs-1.0.0-emmc-fixed-v42.img` | Last good kernel/display before v43 rootfs patch (no WiFi grow stack) |
| `rk3308bs-1.0.0-emmc-fixed-v14.img` | Old baseline  -  v13 thermal + built-in DRM, no custom WiFi/LCD module load |
| `rk3308bs-1.0.0-emmc-fixed-v13.img` | v11 serial + factory RK3308BS TSADC  -  **do not use** (reboot breaks GPT; LCD blank) |
| `rk3308bs-1.0.0-emmc-fixed-v12.img` | v11 serial + **no thermal emergency reboot** (soc-crit passive workaround) |
| `rk3308bs-1.0.0-emmc-fixed-v11.img` | Factory DTB + ttyS3 serial  -  **still thermal reboot loop on 6.18** |

**Do not use an old `-emmc-fixed.img` from before 2026-06-11**  -  those had a broken `boot.img` header (resource.img in wrong slot  ->  U-Boot PXE/`=>` prompt).

Factory GPT layout (reference):

| # | LBA | Size | Name |
|---|-----|---|---|
| 1 | 0x2000 | 0x1000 | uboot |
| 2 | 0x3000 | 0x1000 | trust |
| 3 | 0x4000 | 0x800 | misc |
| 4 | 0x4800 | 0xa000 | recovery |
| 5 | 0xe800 | 0x4800 | boot (9 MB factory) |
| 6 | 0x13000 | grow | rootfs |

The `-fixed` Armbian image expands boot to **17 MB** (`0x8a00`) and moves rootfs to `0x17200`  -  required for Armbian 6.18 `boot.img`. Upgrade with `Gpt=1` rebuilds GPT from `parameter.txt` inside the package.

---

## Working flash log (June 4  -  factory, Upgrade tab)

```
Download Boot Success
Download IDB Success
Download Firmware Start
  Gpt=1, DirectLBA=1
  Start to download trust, offset=0x3000
  Start to download uboot, offset=0x2000
  Start to download boot,   offset=0xe800
  Start to download rootfs, offset=0x13000   Ã¢â€ Â ~5 GB, several minutes
  Start to download recovery, offset=0x4800
  Start to download misc, offset=0x4000
Download Firmware Success
Reset Device Success
```

---

## Broken flash patterns (June 9  -  do NOT do this)

### Pattern A  -  Write by address / custom config

```
Download parameter at 0x00000000 ...     Ã¢â€ Â destroys GPT at LBA 0
RunProc is ending, ret=1
ERROR: GetParameter_Loader->Check parameter tag failed!
```

Cause: **Advanced  ->  Write by address**, or a `config.cfg` that lists `parameter`, `uboot`, `boot`, etc. as separate files instead of one monolithic `.img`.

### Pattern B  -  partial partition list without Gpt=1

```
Download uboot at 0x00002000 ...
Download trust at 0x00003000 ...
Download boot at 0x0000e800 ...
Download armbian-serial-soc at 0x00000000 ...   Ã¢â€ Â wrong item at LBA 0
RunProc is ending, ret=1
```

Cause: custom config pointing at loose `.img`/`.bin` files (not the monolithic update package).

### Pattern C  -  flash too fast

Flash finishes in under ~30 seconds on a multi-GB image  ->  only loader/IDB written, not full firmware.

---

## What each symptom means

| Symptom | Cause |
|------|-----|
| Instant MASKROM, no button | IDB / boot sectors corrupt (bad or partial flash) |
| No partition table in MASKROM | GPT never created (`Gpt=1` path not run) |
| U-Boot `=>` + pxelinux / PXE | Boot partition empty, **truncated boot.img**, or **broken boot.img header** |
| `boot partition is not enough to save image!` | Use `rk3308bs-1.0.0-emmc-fixed.img` (17 MB boot slot) |

---

## Serial

After successful recovered v67 flash: **UART3 @ 1500000**, console **`ttyS3`** (older factory notes mention `ttyFIQ0`).

Verify:

```bash
cat /etc/rk3308bs-release
```

---

## PXE / `=>` prompt after Armbian flash (troubleshooting)

That output means **U-Boot never started the kernel**  -  it is not a rootfs issue yet.

### If you see MASKROM loader output (`Code check error -1`, `tag:LOADER error`)

**Cause:** `rk3308bs-1.0.0-emmc-fixed-v4.img` patched `uboot.img` and broke Rockchip's hash check. **Do not use v4.**

**Recovery:**

1. MASKROM  ->  flash **factory** `KLP_IMG_ARTILLERY_..._Beta.img` (full ~5 GB)
2. Then flash **`rk3308bs-1.0.0-emmc-fixed-v11.img`** (or `rk3308bs-1.0.0-emmc-fixed.img`  -  same as v11)

### `Invalid DTB hash !` / `No valid DTB, ret=-22`

**Cause:** Custom `rk-kernel.dtb` was injected into `resource.img` without updating the RSCE SHA1 entry. U-Boot (`CONFIG_ROCKCHIP_DTB_VERIFY`) rejects the DTB before loading the kernel.

**Fix:** Use **`rk3308bs-1.0.0-emmc-fixed-v6.img`** or newer. v6 rebuilds `boot.img` with correct DTB hash + size in `resource.img`.

Serial symptom (v5 and earlier):

```
DTB: rk-kernel.dtb
HASH(c): error
Invalid DTB hash !
Failed to load android image
```

After v6+ you should see `HASH(c): OK`. If boot then **loops** with overlap/`overwritten` errors, flash **v7** (see below).

### Boot loop: kernel overlaps FDT (`Sysmem Error` / `image overwritten`)

**Cause:** Armbian 6.18 decompresses to ~40 MiB starting at `0x00280000`, but factory U-Boot places the FDT at `fdt_addr_r=0x01f00000` (~31 MiB). The kernel clobbers the device tree  ->  U-Boot resets  ->  loop.

Serial symptom (v6):

```
HASH(c): OK
Booting LZ4 kernel at 0x02480000(Uncompress to 0x00280000) with fdt at 0x01f00000
Sysmem Error: "UNCOMP_KERNEL" ... overlap with existence "FDT" (0x01f00000 ...)
ERROR: new format image overwritten - must RESET the board to recover
```

**Fix:** Flash **`rk3308bs-1.0.0-emmc-fixed-v7.img`** (v6 boot + patched `uboot.img` memory map **with corrected LOADER hash**). v4 had the same env patch but a broken hash (`Code check error -1`); v7 adds the `hash_by_crypto` value the MiniLoader expects.

Expected after v7:

```
HASH(c): OK
... with fdt at 0x05000000
Starting kernel ...
```

### Kernel panic: `Unable to mount root fs on unknown-block(0,0)`

**Cause:** Rockchip U-Boot passes **`/chosen/bootargs` from the DTB** to Linux, not the `boot.img` header cmdline. Custom DTB only had `console=`  -  no `root=PARTUUID=...`  -  so the kernel panics even though boot succeeds.

Serial symptom (v7):

```
Kernel command line: ... console=ttyS3,1500000n8
VFS: Cannot open root device "" or unknown-block(0,0)
Kernel panic - not syncing: VFS: Unable to mount root fs
```

Partition list shows rootfs at **`mmcblk0p6`** / **`614e0000-0000-4b53-8000-1d28000054a9`**  -  the data is there; the kernel just wasn't told where to mount.

**Fix:** Flash **`rk3308bs-1.0.0-emmc-fixed-v8.img`** (v7 + DTB `bootargs` with `root=PARTUUID=614e0000-0000-4b53-8000-1d28000054a9 rootfstype=ext4 rw rootwait`).

Expected after v8:

```
Kernel command line: ... root=PARTUUID=614e0000-0000-4b53-8000-1d28000054a9 rootfstype=ext4 rw rootwait
EXT4-fs (mmcblk0p6): mounted filesystem with ordered data mode
```

### Boot loop after Ã¢â‚¬Å“Welcome to ArmbianÃ¢â‚¬Â (`Temperature too high`)

**Cause:** Custom DTB (v8) is missing the factory **`/otp`** node used to calibrate the TSADC. The sensor reads too hot  ->  instant critical trip  ->  `reboot: HARDWARE PROTECTION shutdown`  ->  loop. v8 otherwise works (root mounts, systemd starts).

Serial symptom:

```
Welcome to Armbian-unofficial 26.08.0-trunk bookworm!
thermal thermal_zone1: soc-thermal: critical temperature reached
reboot: HARDWARE PROTECTION shutdown (Temperature too high)
```

**Fix (serial + root):** v8/v11 bootargs and ttyS3. **Thermal loop:** use **v13** (proper TSADC) or **v12** workaround (passive soc-crit).

**Do not** run manual `saveenv` unless v7 still fails  -  v7+ bakes the memory layout into default env.

### No serial output / boot loop (v9 - v10)

**Cause:** Factory DTB **disables** `serial@ff0d0000` and routes UART3 through **fiq-debugger** (`console=ttyFIQ0`). That works on factory kernel **5.10**, but **Armbian 6.18 does not ship fiq-debugger**  -  so neither `ttyFIQ0` nor `ttyS3` works after `earlycon`, and the serial port goes silent while the board keeps resetting (thermal/display activity may still occur).

v8 had serial because the **custom DTB** enabled `serial@ff0d0000` + `console=ttyS3` (but lacked factory OTP  ->  thermal loop).

**Fix:** Flash **`rk3308bs-1.0.0-emmc-fixed-v11.img`**  -  factory DTB (OTP/thermal) with **fiq-debugger disabled**, **`serial@ff0d0000=okay`**, **`console=ttyS3,1500000n8`**. Same UART header @ **1500000**.

**Note:** v11 serial works, but Armbian **6.18** still hits `soc-thermal: critical temperature reached` ~1 s after boot (factory `/otp` in DTB is not enough for mainline TSADC trim). See **v12** below.

Expected after **v13** (preferred) or **v12** (workaround):

```
Kernel command line: ... console=ttyS3,1500000n8 root=PARTUUID=614e0000-0000-4b53-8000-1d28000054a9 ...
Welcome to Armbian-unofficial ...
rk3308bs login:
```

On **v13**, also check idle temperature is sane (not instant critical trip):

```
cat /sys/class/thermal/thermal_zone0/temp
# expect ~30000 - 50000 (millidegrees C) at room temp
```

### Thermal reboot ~1 s after boot (v8, v11)

**Cause:** TSADC reads too hot without mainline OTP trim  ->  instant **critical** trip  ->  `reboot: HARDWARE PROTECTION shutdown (Temperature too high)`  ->  looks like a very fast boot loop. Serial **does** work on v11 (full dmesg through USB/MMC init, then reboot at ~1 s).

```
thermal_sys: No trip points found for tsadc id=1
thermal thermal_zone0: soc-thermal: critical temperature reached
reboot: HARDWARE PROTECTION shutdown (Temperature too high)
```

v8 reached `Welcome to Armbian` first (custom DTB, no factory OTP) then the same thermal shutdown. v9 - v11 kept factory OTP in DTB but **6.18** still reboots early.

**Fix:** Flash **`rk3308bs-1.0.0-emmc-fixed-v13.img`**  -  factory DTB + ttyS3 + kernel **`rockchip,rk3308bs-tsadc`** linear conversion (see **`THERMAL_RK3308BS.md`**).

**Workaround (no kernel rebuild):** **`rk3308bs-1.0.0-emmc-fixed-v12.img`**  -  same as v11 but **`soc-crit` downgraded to passive** so Linux does not emergency-reboot (readings still wrong; trips disabled).

### Armbian 6.18 kernel + factory U-Boot memory layout (manual fallback)

Factory `uboot.img` only leaves ~25 MiB for a decompressed kernel (`kernel_addr_r=0x00680000`, `fdt_addr_r=0x01f00000`). Armbian 6.18 is larger  ->  `boot_android` fails  ->  PXE/`=>`.

**Manual fallback only** (v5/v6 at `=>` with `bootdelay` > 0). v7 should not need this:

```
setenv fdt_addr_r 0x05000000
setenv kernel_addr_r 0x02080000
setenv kernel_addr_c 0x08000000
saveenv
reset
```

If `saveenv` succeeds, the next boot should load the kernel (watch for Linux messages, not PXE).

### Checklist (normal flash path)

1. **Factory recovery first**  -  flash `KLP_IMG_ARTILLERY_..._Beta.img` (full ~5 GB, `rootfs @ 0x13000`). Confirm the board boots factory again.

2. **Flash the fixed Armbian image**  -  **`rk3308bs-1.0.0-emmc-fixed-v14.img`** (v7 uboot + v14 boot/kernel + reboot-safe rootfs).  
   **Never** use `-v4.img` (patched uboot **without** hash fix  -  bricks at loader).  
   **Avoid v13** after first boot  -  Armbian resize corrupts fixed GPT (see below).

3. **Read the RKDevTool log**  -  both lines are required:
   ```
   Start to download boot, offset=0xe800, size=14630912
   Start to download rootfs, offset=0x17200, size=1647312896
   ```
   (v12 used `size=18040832` for boot  -  still valid if you flash v12. Boot must fit the 17 MiB partition.)
   If `rootfs` is missing (log shows `total=33613312` only), the rootfs partition is empty  -  see **Option B** in the main guide (Advanced  ->  write `rootfs.img` at **`0x17200`**).

4. **At the U-Boot `=>` prompt** (optional diagnosis):
   ```
   mmc dev 0
   mmc part
   ```
   Boot partition must be **~17 MiB** (not 9 MiB). If it still shows 9 MiB, parameter/GPT did not update  -  redo step 1, then step 2.

### Why this happens

| Cause | What happened |
|----|----------|
| `Invalid DTB hash` | Custom DTB in `resource.img` without RSCE SHA1 update (fixed in v6+) |
| Boot loop / `image overwritten` | Kernel decompress overlaps FDT at `0x01f00000` (fixed in v7 uboot env + hash) |
| Kernel panic `unknown-block(0,0)` | DTB missing `root=PARTUUID=...` in `/chosen/bootargs` (fixed in v8+) |
| Thermal reboot (~1 s or after banner) | TSADC uncalibrated on Armbian 6.18 (fix: v13+ RK3308BS linear TSADC; workaround: v12 passive soc-crit) |
| Reboot hang / kernel panic after first boot | `armbian-resize-filesystem` expanded rootfs GPT on eMMC  -  U-Boot shows empty part 5 name and wrong size; fixed in **v14** (`/root/.no_rootfs_resize`) |
| Blank LCD after Linux | DRM built as modules but not installed (v13); fixed in **v14** (built-in `CONFIG_DRM_ROCKCHIP=y`) |
| Silent serial / boot loop on v9 - v10 | Factory DTB disables UART3 unless fiq-debugger works (Armbian 6.18 has none)  -  fixed in v11 |
| `Code check error -1` | Patched uboot without LOADER hash update (v4; fixed in v7) |
| Old `-emmc-fixed.img` | `boot.img` had `resource.img` in ramdisk slot instead of second slot  ->  U-Boot rejects it |
| v43 `Authentication failure` / `bogus i_mode (644)` | Rootfs corrupted by `patch-rootfs-v17-debugfs.sh`. **Full flash v45** after building (not update over grown eMMC) |
| No v44 firmware | v44 script existed but **never built**  -  use `tools/build-release-v45-rootfs-only.sh` |
| Partial flash (`total=33613312`) | Boot written but rootfs skipped; GPT may not match |
| 9 MiB boot slot + 17 MiB boot.img | U-Boot reads truncated image  ->  same PXE symptom |

## Erase vs partition table (important)

**RKDevTool "Erase Flash" does NOT remove the GPT.** It wipes partition *data* (zeros flash blocks). The partition table layout often persists or is immediately **rebuilt** on the next flash.

| Action | GPT effect | Data effect |
|-----|------|-------|
| **Erase Flash** (Advanced) | GPT usually **unchanged** | Partition contents zeroed |
| **Upgrade Firmware** + monolithic `.img` | **`Gpt=1` rebuilds GPT** from `parameter.txt` inside the image | Writes trust, uboot, boot, rootfs, etc. |
| **Factory full image** flash | Full GPT + all partitions | Clean baseline |

**Only Upgrade Firmware** (main tab) with a complete `rk3308bs-*.img` rebuilds GPT correctly *and* writes partition data. Erase alone is never enough.

### What your 12:30 flash did (Putty + RKDevTool log)

```
total=30342656          boot-only (~1 sec)  -  wrong image (v46 grow-only)
Gpt=1                   GPT rebuilt  ->  rootfs *name* appeared (grow size 0xe78ddf)
(no rootfs line)        rootfs *data* never written  ->  empty/corrupt rootfs
```

Putty then shows `LoadTrustBL error:-3` / `No find trust.img!`  -  trust area invalid after erase + incomplete flash.

### Correct recovery sequence

1. **Do not rely on Erase** to fix GPT  -  it will not clear the table.
2. MASKROM  ->  **Upgrade Firmware** (main tab, NOT Advanced write-by-address).
3. Select **`rk3308bs-1.0.0-emmc-fixed-v47.img`** (~1.68 GB).
4. **Before clicking Run**, confirm image file size ~1.6 GB on disk.
5. Log **must** show:
   ```
   total=1677655552
   Start to download rootfs,offset=0x17200,size=1647312896
   ```
   (~47 - 48 seconds for rootfs). If `total=30342656`, STOP  -  wrong image or wrong mode.
6. After success, GPT should show part 6 **rootfs** @ `0x17200` (size may display as grow `0xe78ddf`  -  OK if rootfs data was written).

### Putty logs

Save session logs to `C:\Workspaces\Putty-log\` for boot/flash verification.

## Boot hang at "clk: Disabling unused clocks"

**Symptom:** Serial stops after `clk: Disabling unused clocks`. No login, no panic.

**Cause:** eMMC (`mmc0`) never creates `mmcblk0`. Kernel blocks on `rootwait` for `PARTUUID=614e0000-...`.

Compare to factory dmesg (works):
```
mmc0 HS200 -> Waiting for root -> Successfully tuned phase -> mmcblk0 -> EXT4 mount
```

v48 PuTTY log (hangs):
```
mmc2: SD card detected (mmcblk2)   <- SD slot occupied
mmc0 HS200
(no "Successfully tuned phase")
(no mmcblk0)
clk: Disabling unused clocks
```

**Fix:** Remove the microSD card from the printer before boot. Factory images were tested with an empty SD slot. SD probe on `mmc@ff480000` (mmc2) can prevent eMMC tuning from completing.

**Verify after removing SD:**
- `dwmmc_rockchip ff490000.mmc: Successfully tuned phase to ...`
- `mmcblk0: mmc0:0001 ...`
- `EXT4-fs (mmcblk0p6): mounted filesystem`
- autologin on ttyFIQ0

SD slot can be used after boot for extra storage; avoid booting with a card inserted until we add a DT defer fix.
