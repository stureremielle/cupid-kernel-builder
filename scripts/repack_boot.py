#!/usr/bin/env python3
"""
Replace the kernel inside an Android boot image (header v3/v4) and re-sign it.

Why re-sign: LineageOS boot images are AVB-signed and the AVB footer contains
ABSOLUTE offsets plus a hash of the kernel/ramdisk. Copying the old footer
after changing the kernel produces an image whose footer points at the wrong
place (or whose hash is stale). The bootloader then rejects the image and drops
to fastboot.

This script:
  1. keeps the stock header, cmdline and ramdisk;
  2. swaps in the new Image and pads to the boot partition size;
  3. uses the bundled AOSP `avbtool` to add a fresh, correctly-placed AVB hash
     footer (unsigned "Algorithm: NONE", exactly like LineageOS' own boot.img).

Usage:
    python3 repack_boot.py --stock boot.img --image Image --out boot-new.img
    python3 repack_boot.py --stock boot.img --image Image --out boot-new.img \
        --partition-size 201326592

If avbtool/openssl is unavailable, --strip-avb produces an unsigned image
padded to the partition size (works when vbmeta verification is disabled, as on
LineageOS).
"""

from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys

PAGE = 4096
MAGIC = b"ANDROID!"
AVB_FOOTER_MAGIC = b"AVBf"
AVB_FOOTER_SIZE = 64
HDR_V3_SIZE = 1580
HDR_V4_SIZE = 1584

# Xiaomi 12 (cupid) boot partition: 0x0C000000
DEFAULT_PARTITION_SIZE = 201326592


def align(value: int, page: int = PAGE) -> int:
    return (value + page - 1) & ~(page - 1)


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def find_avbtool() -> str | None:
    here = os.path.dirname(os.path.abspath(__file__))
    avbtool = os.path.join(here, "avb", "avbtool.py")
    return avbtool if os.path.isfile(avbtool) else None


def make_unsigned_image(header: bytes, kernel: bytes, ramdisk: bytes) -> bytes:
    out = bytearray()
    out += header + b"\x00" * (PAGE - len(header))
    out += kernel + b"\x00" * (align(len(kernel)) - len(kernel))
    out += ramdisk + b"\x00" * (align(len(ramdisk)) - len(ramdisk))
    return bytes(out)


def add_avb_footer(unsigned: bytes, out_path: str, partition_size: int) -> None:
    avbtool = find_avbtool()
    if not avbtool:
        fail("scripts/avb/avbtool.py is missing")

    tmp = out_path + ".unsigned"
    with open(tmp, "wb") as f:
        f.write(unsigned)

    # LineageOS' own boot.img uses an unsigned (Algorithm: NONE) hash footer.
    # Match that: no key, no openssl, and the bootloader only needs the hash.
    cmd = [
        sys.executable, avbtool, "add_hash_footer",
        "--image", tmp,
        "--partition_size", str(partition_size),
        "--partition_name", "boot",
        "--algorithm", "NONE",
        # Fixed salt: public, reproducible, and avoids /dev/urandom on Windows.
        "--salt", "00" * 32,
    ]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail(f"avbtool failed (exit {exc.returncode}). Use --strip-avb to produce an unsigned image.")

    os.replace(tmp, out_path)


def strip_or_rebase_avb(stock: bytes, old_tail_start: int, unsigned: bytes,
                        partition_size: int, strip: bool) -> bytes:
    """Fallback when avbtool is unavailable.

    Rebase the existing vbmeta/footer to the new image and move the footer to
    the end of the partition. The vbmeta hash is stale, but LineageOS vbmeta
    disables verification, so this still boots.
    """
    if strip:
        out = bytearray(unsigned)
        if len(out) > partition_size:
            fail("new image is larger than the partition")
        out += b"\x00" * (partition_size - len(out))
        return bytes(out)

    trailing = stock[old_tail_start:]
    if len(trailing) < AVB_FOOTER_SIZE or trailing[-64:-60] != AVB_FOOTER_MAGIC:
        out = bytearray(unsigned)
        out += b"\x00" * (partition_size - len(out))
        return bytes(out)

    footer = trailing[-AVB_FOOTER_SIZE:]
    vbmeta_size = struct.unpack_from(">Q", footer, 28)[0]
    if vbmeta_size == 0 or vbmeta_size > len(trailing):
        fail("could not parse AVB footer")

    vbmeta = trailing[:vbmeta_size]
    if vbmeta[:4] != b"AVB0":
        fail("AVB metadata does not start with AVB0")

    new_offset = len(unsigned)
    if new_offset + vbmeta_size + AVB_FOOTER_SIZE > partition_size:
        fail("new image does not fit in the boot partition")

    new_footer = bytearray(AVB_FOOTER_SIZE)
    new_footer[0:4] = AVB_FOOTER_MAGIC
    struct.pack_into(">II", new_footer, 4, 1, 0)
    struct.pack_into(">Q", new_footer, 12, new_offset)  # original_image_size
    struct.pack_into(">Q", new_footer, 20, new_offset)  # vbmeta_offset
    struct.pack_into(">Q", new_footer, 28, vbmeta_size)

    out = bytearray(unsigned)
    out += vbmeta
    out += b"\x00" * (partition_size - AVB_FOOTER_SIZE - len(out))
    out += new_footer
    return bytes(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Replace the kernel in boot.img and re-sign it")
    parser.add_argument("--stock", required=True, help="stock boot.img (LineageOS image)")
    parser.add_argument("--image", required=True, help="new kernel Image")
    parser.add_argument("--out", required=True, help="output boot.img")
    parser.add_argument("--partition-size", type=int, default=DEFAULT_PARTITION_SIZE,
                        help=f"boot partition size in bytes (default {DEFAULT_PARTITION_SIZE} for cupid)")
    parser.add_argument("--strip-avb", action="store_true",
                        help="produce an unsigned image padded to the partition instead of re-signing")
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
        fail(f"unsupported boot header v{header_version}; supports v3/v4")
    expected_header = HDR_V4_SIZE if header_version == 4 else HDR_V3_SIZE
    if header_size != expected_header:
        print(f"warning: header_size is {header_size}, expected {expected_header}", file=sys.stderr)

    kernel_off = PAGE
    ramdisk_off = align(kernel_off + kernel_size)
    tail_start = align(ramdisk_off + ramdisk_size)
    if ramdisk_off + ramdisk_size > len(boot):
        fail("stock boot image is truncated (ramdisk extends past end of file)")

    ramdisk = boot[ramdisk_off:ramdisk_off + ramdisk_size]

    header = bytearray(boot[:header_size])
    struct.pack_into("<I", header, 8, len(kernel))

    unsigned = make_unsigned_image(bytes(header), kernel, ramdisk)
    if len(unsigned) > args.partition_size:
        fail(f"new image is {len(unsigned):,} bytes, partition is {args.partition_size:,}")

    avbtool = find_avbtool()
    if not args.strip_avb and avbtool:
        add_avb_footer(unsigned, args.out, args.partition_size)
        mode = "AVB hash footer added (unsigned, matches LineageOS)"
    else:
        signed = strip_or_rebase_avb(boot, tail_start, unsigned, args.partition_size, args.strip_avb)
        with open(args.out, "wb") as f:
            f.write(signed)
        mode = ("unsigned (AVB stripped)" if args.strip_avb
                else "AVB footer rebased (stale hash; verification must be disabled)")

    size = os.path.getsize(args.out)
    print(f"stock boot:   {len(boot):,} bytes, header v{header_version}, "
          f"kernel {kernel_size:,}, ramdisk {ramdisk_size:,}")
    print(f"new kernel:   {len(kernel):,} bytes")
    print(f"new boot.img: {size:,} bytes -> {args.out}")
    print(f"AVB: {mode}")

    # Structural check: footer at the end of the partition points at AVB0.
    with open(args.out, "rb") as f:
        out = f.read()
    if len(out) >= AVB_FOOTER_SIZE and out[-64:-60] == AVB_FOOTER_MAGIC:
        off = struct.unpack_from(">Q", out, len(out) - 64 + 20)[0]
        if off + 4 > len(out) or out[off:off + 4] != b"AVB0":
            fail(f"AVB footer verification failed: offset {off} does not point to AVB0")
        print(f"AVB footer:   OK (vbmeta at {off:,})")
    elif not args.strip_avb:
        print("AVB footer:   none (unsigned image)", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
