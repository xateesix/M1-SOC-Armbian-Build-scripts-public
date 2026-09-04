#!/usr/bin/env python3
"""Replace the main DTB inside a Rockchip resource.img (preserve bundle size)."""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path


def find_largest_fdt(data: bytes) -> tuple[int, int]:
    magic = b"\xd0\x0d\xfe\xed"
    candidates: list[tuple[int, int]] = []
    offset = 0
    while True:
        idx = data.find(magic, offset)
        if idx < 0:
            break
        if idx + 8 <= len(data):
            totalsize = struct.unpack(">I", data[idx + 4 : idx + 8])[0]
            if 64 <= totalsize <= len(data) - idx:
                candidates.append((totalsize, idx))
        offset = idx + 4
    if not candidates:
        raise SystemExit("No FDT magic found in resource.img template")
    totalsize, off = max(candidates, key=lambda x: x[0])
    # Rockchip resource.img leaves zero padding after the FDT blob; allow reuse.
    slot_end = off + totalsize
    while slot_end < len(data) and data[slot_end] == 0 and (slot_end - off) <= 65536:
        slot_end += 1
    return slot_end - off, off


def find_entr_entry(data: bytes, name: str) -> int:
    needle = b"ENTR" + name.encode("ascii") + b"\x00"
    idx = data.find(needle)
    if idx < 0:
        raise SystemExit(f"ENTR entry {name!r} not found in resource.img")
    return idx


def update_entr_hash_and_size(out: bytearray, entr_off: int, new_dtb: bytes) -> None:
    """Rockchip U-Boot verifies SHA1 of rk-kernel.dtb (CONFIG_ROCKCHIP_DTB_VERIFY)."""
    hash_off = entr_off + 0xE0
    size_off = entr_off + 0x108
    if hash_off + 20 > len(out) or size_off + 4 > len(out):
        raise SystemExit(f"ENTR metadata out of range @ 0x{entr_off:x}")

    sha1 = hashlib.sha1(new_dtb).digest()
    out[hash_off : hash_off + 20] = sha1
    struct.pack_into("<I", out, size_off, len(new_dtb))


def patch_dtb(template: bytes, new_dtb: bytes) -> bytes:
    old_size, off = find_largest_fdt(template)
    if len(new_dtb) > old_size:
        raise SystemExit(
            f"New DTB ({len(new_dtb)} bytes) exceeds slot in template ({old_size} bytes @ 0x{off:x}). "
            "Rebuild DTS or use a smaller overlay."
        )

    out = bytearray(template)
    out[off : off + len(new_dtb)] = new_dtb
    # Update FDT totalsize field in place
    struct.pack_into(">I", out, off + 4, len(new_dtb))
    # Zero pad remainder of old slot
    if len(new_dtb) < old_size:
        out[off + len(new_dtb) : off + old_size] = b"\x00" * (old_size - len(new_dtb))

    update_entr_hash_and_size(out, find_entr_entry(bytes(out), "rk-kernel.dtb"), new_dtb)
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--template", required=True, type=Path, help="Factory resource.img template")
    ap.add_argument("--dtb", required=True, type=Path, help="New board DTB")
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()

    template = args.template.read_bytes()
    new_dtb = args.dtb.read_bytes()
    if new_dtb[:4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit(f"Not a DTB: {args.dtb}")

    out = patch_dtb(template, new_dtb)
    args.output.write_bytes(out)
    old_size, off = find_largest_fdt(template)
    print(f"Wrote {args.output} ({len(out)} bytes)")
    print(f"  replaced FDT @ 0x{off:x}: {old_size} -> {len(new_dtb)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
