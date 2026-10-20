# Bundled AOSP avbtool

`avbtool.py` is vendored from LineageOS' `android_external_avb`
(branch `lineage-24.0`), originally from AOSP `external/avb`.

It is used by `scripts/repack_boot.py` to add a correctly placed AVB hash
footer to the repacked boot image. The footer must sit at the end of the boot
partition and its `vbmeta_offset` must point at the relocated `AVB0` metadata;
copying the stock footer unchanged produces an image the bootloader rejects.

`avbtool.py` is licensed under the Apache License 2.0 (see the header in the
file). No signing key is used: LineageOS' own boot image has an unsigned
(`Algorithm: NONE`) hash footer, and this tool reproduces that.
