#!/usr/bin/env python3
"""Patch factory uboot.img default env for Armbian 6.18 LZ4 kernels + fix LOADER hash.

Factory layout puts fdt_addr_r at 0x01f00000 while the 6.18 kernel decompresses to
~0x00280000 and grows past 0x02900000, overlapping the FDT  ->  boot loop.

Same-length env replacements preserve the embedded env struct. After patching, both
LOADER headers (0x0 and 0x100000) need hash_in_hdr updated to hash_by_crypto or the
MiniLoader rejects the image (Code check error -1).

The hash for this exact patch was captured from MASKROM debug on v4:
  hash_by_crypto = 602d37ec9cc9e7e25afb4ae33f683e57...
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# Each pair must be exactly the same byte length.
REPLACEMENTS: tuple[tuple[bytes, bytes], ...] = (
    (b"fdt_addr_r=0x01f00000", b"fdt_addr_r=0x05000000"),
    (b"kernel_addr_r=0x00680000", b"kernel_addr_r=0x02080000"),
    (b"kernel_addr_c=0x02480000", b"kernel_addr_c=0x08000000"),
)

# hash_by_crypto for the three replacements above (from v4 MASKROM serial).
PATCHED_HASH = bytes.fromhex(
    "602d37ec9cc9e7e25afb4ae33f683e57"
    "7bbdbb6f4c4ba51e1ac927ae2ef5670f"
)

LOADER_MAGIC = b"LOADER  "
LOADER_STRIDE = 0x100000
HASH_OFF = 0x20
HASH_LEN = 32


def patch_uboot(src: Path, dst: Path) -> None:
    data = bytearray(src.read_bytes())
    changed = False
    for old, new in REPLACEMENTS:
        if len(old) != len(new):
            raise SystemExit(f"length mismatch: {old!r} vs {new!r}")
        count = data.count(old)
        if count:
            data = data.replace(old, new)
            print(f"  {old.decode()} -> {new.decode()} ({count}x)")
            changed = True
            continue
        if data.count(new):
            print(f"  already patched: {new.decode()} present ({data.count(new)}x)")
            continue
        raise SystemExit(f"pattern not found in {src}: {old!r} and not already patched with {new!r}")

    for base in (0, LOADER_STRIDE):
        if data[base : base + 8] != LOADER_MAGIC:
            raise SystemExit(f"LOADER magic missing @ 0x{base:x}")
        current_hash = data[base + HASH_OFF : base + HASH_OFF + HASH_LEN]
        if current_hash != PATCHED_HASH:
            data[base + HASH_OFF : base + HASH_OFF + HASH_LEN] = PATCHED_HASH
            size = struct.unpack_from("<I", data, base + 0x14)[0]
            print(f"  hash @ 0x{base + HASH_OFF:x} updated (body size 0x{size:x})")
        else:
            print(f"  hash @ 0x{base + HASH_OFF:x} already matches patched value")

    dst.write_bytes(data)
    print(f"Wrote {dst} ({len(data)} bytes)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("uboot", type=Path, help="Factory uboot.img")
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    patch_uboot(args.uboot, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
