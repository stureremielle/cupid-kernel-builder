#!/usr/bin/env python3
"""
Replace the kernel inside an Android boot image (header v3/v4).

Used to turn the freshly built Image into a fastboot-flashable boot.img
without needing magiskboot or a full LineageOS build tree.

Usage:
    python3 repack_boot.py --stock boot.img --image Image --out boot-new.img

The script keeps the original ramdisk, command line, OS version and boot
signature. Only the kernel payload and the kernel_size header field change.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

PAGE = 4096
MAGIC = b"ANDROID!"
HDR_V3_SIZE = 1580
HDR_V4_SIZE = 1584


def align(value: int, page: int = PAGE) -> int:
    return (value + page - 1) & ~(page - 1)


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def main() -> int:
    parser = argparse.ArgumentParser(description="Replace the kernel in boot.img (header v3/v4)")
    parser.add_argument("--stock", required=True, help="stock boot.img")
    parser.add_argument("--image", required=True, help="new kernel Image")
    parser.add_argument("--out", required=True, help="output boot.img")
    parser.add_argument("--drop-signature", action="store_true",
                        help="remove the AVB boot signature (safe when vbmeta disables verification)")
    args = parser.parse_args()

    if not os.path.isfile(args.stock):
        fail(f"stock image not found: {args.stock}")
    if not os.path.isfile(args.image):
        fail(f"kernel Image not found: {args.image}")

    with open(args.stock, "rb") as f:
        boot = f.read()
    with open(args.image, "rb") as f:
        kernel = f.read()

    if len(boot) < PAGE or boot[:8] != MAGIC:
        fail("not an Android boot image (bad ANDROID! magic)")

    kernel_size = read_u32(boot, 8)
    ramdisk_size = read_u32(boot, 12)
    header_size = read_u32(boot, 20)
    header_version = read_u32(boot, 40)

    if header_version not in (3, 4):
        fail(
            f"unsupported boot header v{header_version}; this script supports v3/v4 "
            "(Xiaomi 12 / LineageOS uses v4)"
        )
    expected_header = HDR_V4_SIZE if header_version == 4 else HDR_V3_SIZE
    if header_size != expected_header:
        print(
            f"warning: header_size is {header_size}, expected {expected_header} for v{header_version}",
            file=sys.stderr,
        )

    signature_size = read_u32(boot, 1580) if header_version == 4 else 0

    kernel_off = PAGE
    ramdisk_off = align(kernel_off + kernel_size)
    signature_off = align(ramdisk_off + ramdisk_size)

    if ramdisk_off + ramdisk_size > len(boot):
        fail("stock boot image is truncated (ramdisk extends past end of file)")

    ramdisk = boot[ramdisk_off:ramdisk_off + ramdisk_size]

    # Everything after the ramdisk (AVB boot signature, and possibly vendor
    # extras) is preserved verbatim. The signature offset shifts with the new
    # kernel, but its position relative to the ramdisk end is unchanged.
    trailing = boot[signature_off:]
    if signature_size and signature_size > len(trailing):
        fail("stock boot image is truncated (signature extends past end of file)")

    # Preserve the original header bytes, only update kernel_size.
    header = bytearray(boot[:header_size])
    struct.pack_into("<I", header, 8, len(kernel))
    if header_version == 4 and args.drop_signature:
        struct.pack_into("<I", header, 1580, 0)
        trailing = b""

    out = bytearray()
    out += bytes(header) + b"\x00" * (PAGE - len(header))
    out += kernel + b"\x00" * (align(len(kernel)) - len(kernel))
    out += ramdisk + b"\x00" * (align(len(ramdisk)) - len(ramdisk))
    if trailing:
        out += trailing + b"\x00" * (align(len(trailing)) - len(trailing))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(out)

    print(f"stock boot:   {len(boot):,} bytes, header v{header_version}, "
          f"kernel {kernel_size:,}, ramdisk {ramdisk_size:,}, signature {signature_size:,}")
    print(f"new kernel:   {len(kernel):,} bytes")
    print(f"new boot.img: {len(out):,} bytes -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
