#!/usr/bin/env python3
"""Grow boot partition in Rockchip parameter.txt to fit boot.img (512-byte sectors)."""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

SECTOR = 512
ALIGN = 0x100  # 128 KiB alignment
# RKDevTool flashes rootfs at boot_end from the Armbian-fixed layout (0xe800+0x8a00=0x17200).
# Do not shrink boot below this or GPT rootfs start and flash offset diverge.
MIN_BOOT_SECTORS = 0x8A00


def boot_sectors(boot_img: Path) -> int:
    size = boot_img.stat().st_size
    need = math.ceil(size / SECTOR)
    return ((need + ALIGN - 1) // ALIGN) * ALIGN


def rootfs_sectors(rootfs_img: Path) -> int:
    size = rootfs_img.stat().st_size
    need = math.ceil(size / SECTOR)
    return ((need + ALIGN - 1) // ALIGN) * ALIGN


def patch_parameter(
    src: Path,
    boot_img: Path,
    dst: Path,
    rootfs_img: Path | None = None,
) -> None:
    text = src.read_text(encoding="utf-8", errors="replace")
    m = re.search(
        r"(0x[0-9a-fA-F]+)@0x([0-9a-fA-F]+)\(boot\),-@0x([0-9a-fA-F]+)\(rootfs:grow\)",
        text,
    )
    fixed = False
    if not m:
        m = re.search(
            r"(0x[0-9a-fA-F]+)@0x([0-9a-fA-F]+)\(boot\),0x[0-9a-fA-F]+@0x([0-9a-fA-F]+)\(rootfs\)",
            text,
        )
        fixed = bool(m)
    if not m:
        raise SystemExit("Could not find boot/rootfs entries in parameter.txt CMDLINE")

    old_boot_size = int(m.group(1), 16)
    boot_off = int(m.group(2), 16)
    old_root_off = int(m.group(3), 16)
    new_boot_size = max(boot_sectors(boot_img), MIN_BOOT_SECTORS)
    new_root_off = boot_off + new_boot_size

    new_boot_hex = f"0x{new_boot_size:08x}"
    new_root_hex = f"0x{new_root_off:08x}"

    if rootfs_img is not None and rootfs_img.is_file():
        rootfs_size = rootfs_sectors(rootfs_img)
        rootfs_part = f"0x{rootfs_size:08x}@{new_root_hex}(rootfs)"
        rootfs_note = (
            f"# rootfs: explicit {rootfs_size * SECTOR // (1024 * 1024)} MiB at {new_root_hex} "
            f"(explicit size  -  RKDevTool flashes rootfs; do not use :grow suffix)"
        )
    else:
        rootfs_part = f"-@{new_root_hex}(rootfs:grow)"
        rootfs_note = (
            f"# partition size: boot expanded for Armbian 6.18 "
            f"({new_boot_size * SECTOR // (1024 * 1024)} MiB boot), -(rootfs)"
        )

    if fixed:
        new_text = re.sub(
            r"0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(boot\),0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(rootfs\)",
            f"{new_boot_hex}@0x{boot_off:08x}(boot),{rootfs_part}",
            text,
            count=1,
        )
    else:
        new_text = re.sub(
            r"0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(boot\),-@0x[0-9a-fA-F]+\(rootfs:grow\)",
            f"{new_boot_hex}@0x{boot_off:08x}(boot),{rootfs_part}",
            text,
            count=1,
        )
    new_text = re.sub(
        r"# .*?\(boot\),-\(rootfs\).*",
        rootfs_note,
        new_text,
        count=1,
    )
    dst.write_text(new_text, encoding="utf-8")
    boot_mb = boot_img.stat().st_size / (1024 * 1024)
    part_mb = new_boot_size * SECTOR / (1024 * 1024)
    print(f"boot.img: {boot_img.stat().st_size} bytes ({boot_mb:.2f} MiB)")
    print(f"boot partition: 0x{old_boot_size:x} -> {new_boot_hex} ({part_mb:.0f} MiB)")
    print(f"rootfs start:   0x{old_root_off:x} -> {new_root_hex}")
    if rootfs_img is not None and rootfs_img.is_file():
        print(f"rootfs size:    0x{rootfs_sectors(rootfs_img):x} sectors")
    print(f"Wrote {dst}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("parameter", type=Path)
    ap.add_argument("boot_img", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--rootfs",
        type=Path,
        help="If set, use explicit rootfs partition size instead of grow",
    )
    args = ap.parse_args()
    patch_parameter(args.parameter, args.boot_img, args.output, args.rootfs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
