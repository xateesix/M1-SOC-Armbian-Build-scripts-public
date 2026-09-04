#!/usr/bin/env python3
# Patch logo.bmp / logo_kernel.bmp blobs into a Rockchip resource.img template.
from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path

LOGO_DATA_OFF = 0xE200
LOGO_KERNEL_DATA_OFF = 0x6DE00
ENTR_LOGO_OFF = 0x400
ENTR_LOGO_KERNEL_OFF = 0x600
BM_MAGIC = bytes.fromhex('424d')
RSCE_MAGIC = bytes.fromhex('52534345')
PACK_I = chr(60) + chr(73)


def update_entr_hash_and_size(out: bytearray, entr_off: int, blob: bytes) -> None:
    hash_off = entr_off + 0xE0
    size_off = entr_off + 0x108
    if hash_off + 20 > len(out) or size_off + 4 > len(out):
        raise SystemExit('ENTR metadata out of range @ 0x%x' % entr_off)
    out[hash_off : hash_off + 20] = hashlib.sha1(blob).digest()
    struct.pack_into(PACK_I, out, size_off, len(blob))


def patch_slot(out: bytearray, data_off: int, slot_size: int, blob: bytes, entr_off: int, label: str) -> None:
    if len(blob) > slot_size:
        raise SystemExit('%s (%s bytes) exceeds slot (%s bytes @ 0x%x)' % (label, len(blob), slot_size, data_off))
    if data_off + slot_size > len(out):
        raise SystemExit('Slot @ 0x%x extends past resource.img (%s bytes)' % (data_off, len(out)))
    out[data_off : data_off + len(blob)] = blob
    tail = slot_size - len(blob)
    if tail:
        out[data_off + len(blob) : data_off + slot_size] = bytes(tail)
    update_entr_hash_and_size(out, entr_off, blob)


def patch_logos(template: bytes, logo: bytes, logo_kernel: bytes | None) -> bytes:
    if logo[:2] != BM_MAGIC:
        raise SystemExit('logo is not a BMP (missing BM magic)')
    logo_kernel = logo_kernel if logo_kernel is not None else logo
    if logo_kernel[:2] != BM_MAGIC:
        raise SystemExit('logo_kernel is not a BMP (missing BM magic)')
    out = bytearray(template)
    logo_slot = LOGO_KERNEL_DATA_OFF - LOGO_DATA_OFF
    kernel_slot = len(template) - LOGO_KERNEL_DATA_OFF
    patch_slot(out, LOGO_DATA_OFF, logo_slot, logo, ENTR_LOGO_OFF, 'logo.bmp')
    patch_slot(out, LOGO_KERNEL_DATA_OFF, kernel_slot, logo_kernel, ENTR_LOGO_KERNEL_OFF, 'logo_kernel.bmp')
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--template', required=True, type=Path, help='Factory or patched resource.img')
    ap.add_argument('--logo', required=True, type=Path, help='logo.bmp payload')
    ap.add_argument('--logo-kernel', type=Path, default=None, help='logo_kernel.bmp (default: same as --logo)')
    ap.add_argument('--output', required=True, type=Path)
    args = ap.parse_args()

    template = args.template.read_bytes()
    if template[:4] != RSCE_MAGIC:
        raise SystemExit('Not a Rockchip resource.img: %s' % args.template)

    logo = args.logo.read_bytes()
    logo_kernel = args.logo_kernel.read_bytes() if args.logo_kernel else None
    out = patch_logos(template, logo, logo_kernel)
    args.output.write_bytes(out)

    lk = logo_kernel if logo_kernel is not None else logo
    print('Wrote %s (%s bytes)' % (args.output, len(out)))
    print('  logo.bmp @ 0x%x: %s bytes, SHA1 %s' % (LOGO_DATA_OFF, len(logo), hashlib.sha1(logo).hexdigest()))
    print('  logo_kernel.bmp @ 0x%x: %s bytes, SHA1 %s' % (LOGO_KERNEL_DATA_OFF, len(lk), hashlib.sha1(lk).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
