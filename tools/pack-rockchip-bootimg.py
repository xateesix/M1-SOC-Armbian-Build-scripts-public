#!/usr/bin/env python3
"""Assemble Rockchip Android boot.img (LZ4 kernel + optional ramdisk + resource.img second slot)."""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


def page_align(n: int, page_size: int) -> int:
    return (n + page_size - 1) // page_size * page_size


def build_bootimg(
    kernel: bytes,
    second: bytes,
    cmdline: str = "",
    page_size: int = 2048,
    ramdisk: bytes = b"",
    ramdisk_addr: int = 0x01100000,
) -> bytes:
    ks = len(kernel)
    rs = len(ramdisk)
    ss = len(second)
    cmdline_bytes = cmdline.encode("ascii", errors="strict")
    if len(cmdline_bytes) >= 512:
        raise SystemExit(f"cmdline too long ({len(cmdline_bytes)} bytes, max 511)")

    header = bytearray(page_size)
    header[:8] = b"ANDROID!"
    struct.pack_into(
        "<8I",
        header,
        8,
        ks,
        0x10008000,
        rs,
        ramdisk_addr,
        ss,
        0x10F00000,
        0x10000100,
        page_size,
    )
    header[0x50 : 0x50 + len(cmdline_bytes)] = cmdline_bytes

    kernel_off = page_size
    ramdisk_off = kernel_off + page_align(ks, page_size)
    second_off = ramdisk_off + page_align(rs, page_size)
    total = second_off + page_align(ss, page_size)

    out = bytearray(total)
    out[0:page_size] = header
    out[kernel_off : kernel_off + ks] = kernel
    if rs:
        out[ramdisk_off : ramdisk_off + rs] = ramdisk
    out[second_off : second_off + ss] = second
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel", required=True, type=Path, help="LZ4-compressed kernel blob")
    ap.add_argument("--resource", required=True, type=Path, help="Rockchip resource.img")
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--cmdline", default="", help="512-byte boot.img cmdline field")
    ap.add_argument("--ramdisk", type=Path, default=None, help="gzip cpio initramfs for ramdisk slot")
    ap.add_argument("--ramdisk-addr", type=lambda x: int(x, 0), default=0x01100000)
    args = ap.parse_args()

    kernel = args.kernel.read_bytes()
    second = args.resource.read_bytes()
    ramdisk = args.ramdisk.read_bytes() if args.ramdisk else b""
    if len(kernel) == 0:
        raise SystemExit("empty kernel blob")
    if len(second) == 0:
        raise SystemExit("empty resource.img")

    boot = build_bootimg(kernel, second, args.cmdline, ramdisk=ramdisk, ramdisk_addr=args.ramdisk_addr)
    args.output.write_bytes(boot)
    print(f"Wrote {args.output} ({len(boot)} bytes)")
    print(f"  kernel_size={len(kernel)} ramdisk_size={len(ramdisk)} second_size={len(second)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
