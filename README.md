# BakaSU + SUSFS kernel builder — Xiaomi 12 (cupid) / LineageOS

Builds the **LineageOS 5.10 kernel** for the Xiaomi 12 (`cupid`, SM8450) with
**BakaSU** (the project formerly called **ReSukiSU**) and **SUSFS** compiled in,
then packages it as a flashable kernel.

> **ReSukiSU is now BakaSU.** The `ReSukiSU/ReSukiSU` repository redirects to
> [`Baka-SU/BakaSU`](https://github.com/Baka-SU/BakaSU). This builder uses the
> current name/repo. BakaSU is a KernelSU downstream with multi-manager support
> and a built-in SUSFS front-end.
>
> SUSFS support is present in BakaSU **v4.2.0-rc1 and newer**; the older
> v4.1.0 stable tag does not have it. BakaSU's `main` branch currently carries
> a temporary "suspend susfs build" guard while it tracks a new KernelSU
> sync, so this builder defaults to BakaSU's **`sync-susfs`** branch (the
> SUSFS-enabled integration branch). Pin `--ksu` to a commit if you want a
> reproducible build.

---

## What you get

| Output | Purpose |
| --- | --- |
| `dist/Image` | Raw arm64 kernel image |
| `dist/BakaSU-SUSFS-cupid-*.zip` | AnyKernel3 zip (TWRP/OrangeFox/kernel flasher apps) |
| `dist/BakaSU-SUSFS-cupid-*-boot.img` | Fastboot-flashable boot image (when `--stock-boot` is used) |
| `dist/kernel.config` | The exact `.config` used |
| `dist/kernel-release.txt` | Kernel release/vermagic string and build metadata |
| `dist/logs/build.log` | Full build log |

Supported LineageOS versions for `cupid`: **22.2, 23.0, 23.2, 24.0**
(branch names match: `lineage-22.2`, `lineage-23.2`, ...). All of them use the
same `android_kernel_xiaomi_sm8450` 5.10 source tree.

---

## Requirements

* Unlocked bootloader (already required by LineageOS).
* **Linux build host**: WSL2 with Ubuntu, a native Linux machine, or Docker.
  Building Android kernels on native Windows is not supported.
* ~25 GB free disk, 8 GB RAM minimum (16 GB recommended for LTO).
* Python 3 (only for the boot-image repack step).

### Option A — WSL2 on Windows (recommended)

```powershell
wsl --install -d Ubuntu-22.04
# reboot if asked, then open "Ubuntu 22.04"
```

Inside Ubuntu:

```bash
sudo apt update
sudo apt install -y git
git clone <this-repo> ~/cupid-kernel && cd ~/cupid-kernel
chmod +x build.sh scripts/*.sh
./build.sh --install-deps
```

> WSL2 cannot see the phone over USB by default, so `--from-device` and adb
> generally only work in native Linux (or Docker with USB passthrough). On
> Windows, read the release in PowerShell with
> `.\scripts\detect-kernel-release.ps1`, then pass the printed value with
> `--localversion`, or use `--stock-boot` (its kernel release is detected
> automatically).

If WSL has little RAM, create `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=8
swap=8GB
```

then `wsl --shutdown` and reopen Ubuntu.

### Option B — Docker Desktop

```powershell
docker build -t cupid-kernel-builder .
docker run --rm -it -v "${PWD}:/project" -w /project cupid-kernel-builder `
  --work-dir /project/work --help
```

Any `build.sh` flags can be appended to the `docker run` command.

### Option C — GitHub Actions (no local Linux needed)

1. Create a GitHub repository and push this folder.
2. Open **Actions → Build cupid kernel → Run workflow**.
3. Pick the LineageOS branch (default `lineage-24.0`) and run it.
   * Optional, fastest: put the standalone **`boot_img_url`** in the input
     (for 20261015 cupid:
     `https://mirrorbits.lineageos.org/full/cupid/20261015/boot.img`). The
     workflow uses it to detect the exact kernel release and produces a
     **flashable `boot.img`** artifact.
   * Alternative: put the LineageOS OTA zip URL in **`ota_url`**. The workflow
     extracts `boot.img` from the OTA and does the same (larger download).
   * Optional: set **`kernel_ref`** if the phone is not on the newest
     LineageOS build (see “Updating LineageOS” above).
4. Download the artifacts (`Image`, AnyKernel3 zip, optional `boot.img`,
   config, logs).

The workflow uses the same `build.sh`, so the result is identical. The free
runner has a 6-hour limit; `thin` LTO is the default to stay well below it.

---

## Quick start

The kernel release string must match the installed LineageOS build: **vendor
modules (Wi-Fi, camera, ...) refuse to load if the kernel release/vermagic
differs**, and the ROM ships many modules in `vendor_dlkm`/`vendor_boot`.

On native Linux with adb, let the builder read it from the phone:

```bash
./build.sh --from-device
```

On Windows/WSL (where WSL usually cannot see the phone over USB), read the
suffix once and pass it in:

```powershell
.\scripts\detect-kernel-release.ps1
```

```bash
./build.sh --lineage lineage-24.0 --localversion '-gki-geff4b40407a1'
```

The suffix is usually **not** just `-gki` or `-gki+`: LineageOS builds this
kernel with `CONFIG_LOCALVERSION_AUTO=y`, so the stock release includes the
kernel commit hash, e.g. `5.10.269-gki-geff4b40407a1`. Pass everything after
`5.10.269` to `--localversion`, or let `--from-device`/`--stock-boot` read it
automatically.

Best option (also produces the fastboot boot.img and detects the release from
the stock boot image):

```bash
./build.sh --stock-boot /path/to/stock-boot.img
```

Build time is roughly 30–120 minutes depending on CPU. `--lto thin` (default)
is much faster than `--lto full`; LTO mode does not affect module loading.

### All options

```text
--lineage BRANCH     LineageOS kernel branch (default lineage-24.0)
--kernel-ref REF     Build a specific kernel commit instead of the branch tip
--ksu REF            BakaSU tag/commit/branch (default sync-susfs)
--susfs BRANCH       susfs4ksu branch (default: auto, gki-android12-5.10)
--susfs-ref REF      Pin SUSFS to a commit (default: known-good revision;
                     'latest' tracks the branch tip)
--lto MODE           thin (default) or full
--localversion SUF   Hardcode kernel localversion, e.g. '-gki-geff4b40407a1'
--from-device        Read uname -r from the phone with adb
--stock-boot FILE    Stock boot.img, enables boot.img output + version detection
--jobs N             Parallel jobs (default: nproc)
--work-dir DIR       Build directory (default ~/.cache/baka-cupid/work)
--dist-dir DIR       Output directory (default ./dist)
--clang PATH         Use a specific clang
--fast               Disable CONFIG_DEBUG_INFO (faster)
--patch-only         Stop after applying BakaSU + SUSFS
--no-ak3             Skip the AnyKernel3 zip
--fresh              Delete the work directory first
--install-deps       Install apt dependencies and exit
```

The build directory defaults to `~/.cache/baka-cupid/work` **outside** the
project on purpose: the kernel Makefile rejects source paths containing spaces
(and `C:\Users\...\Documents\Default Project` becomes
`/mnt/c/.../Default Project` under WSL).

---

## Flashing

### 1. Fastboot with a boot.img (recommended)

You need the **stock boot.img from the exact LineageOS build installed on the
phone**. You can either pass it to the builder (`--stock-boot`) or repack it
afterwards.

Getting `boot.img` from a LineageOS OTA zip:

1. Download the matching `lineage-*.0-*-cupid.zip` from
   <https://download.lineageos.org/devices/cupid>.
2. Download `payload-dumper-go` from
   <https://github.com/ssut/payload-dumper-go/releases>.
3. Extract the boot partition:

   ```bash
   payload-dumper-go -p boot -o extracted lineage-24.0-*-cupid.zip
   # boot.img is written under extracted/
   # Windows: payload-dumper-go.exe -p boot -o extracted lineage-24.0-*-cupid.zip
   ```

4. Repack with the new kernel (works on Windows, Linux and macOS):

   ```bash
   python3 scripts/repack_boot.py --stock boot.img --image dist/Image --out dist/boot-new.img
   # Windows: python scripts\repack_boot.py --stock boot.img --image dist\Image --out dist\boot-new.img
   ```

   The script pads the result to the 192 MiB boot partition and re-adds a fresh
   AVB hash footer with the bundled `avbtool` (LineageOS uses an unsigned
   `Algorithm: NONE` footer). This is required: a blindly copied stock footer
   points at the old vbmeta offset and the bootloader rejects the image.

   (The builder does this automatically when you pass `--stock-boot boot.img`.)

Flash:

```bash
adb reboot bootloader
fastboot getvar current-slot      # usually a or b
fastboot flash boot dist/boot-new.img
fastboot reboot
```

`fastboot flash boot` writes to the active slot. Keep the original `boot.img`
and flash it the same way if you need to roll back.

> LineageOS vbmeta is built with verification/verity disabled
> (`--flags 3`), so an unsigned boot image is accepted on an unlocked
> bootloader. If you are on a different ROM, check its AVB setup first.

### 2. AnyKernel3 zip

Flash `dist/BakaSU-SUSFS-cupid-*.zip` in a custom recovery (TWRP/OrangeFox)
or with a kernel-flasher app that supports AnyKernel3. The zip only replaces
the kernel inside `boot`; it keeps the stock ramdisk and DTB.

LineageOS Recovery itself only accepts signed OTA packages, so it cannot flash
this zip — use fastboot or a custom recovery.

### 3. First boot / root

1. Boot the phone (first boot can take a few minutes).
2. Install the **BakaSU manager APK** from
   <https://github.com/Baka-SU/BakaSU/releases> (latest release or CI build;
   if you pinned `--ksu` to a tag, use the matching manager). Official
   KernelSU/MKSU/RKSU managers also work thanks to BakaSU's multi-manager
   support.
3. Open the manager, grant root, and use the built-in **SUSFS** page to enable
   the hiding features you need.
4. Optional: install the `susfs4ksu` module from
   <https://gitlab.com/simonpunk/susfs4ksu> if you want the `ksu_susfs` CLI.

Verify:

```bash
adb shell uname -r
# should equal dist/kernel-release.txt
adb shell su -c id
```

---

## How it works

`build.sh` performs these steps:

1. Clones the LineageOS kernel branch (`android_kernel_xiaomi_sm8450`).
2. Integrates **BakaSU** the same way its `kernel/setup.sh` does:
   `KernelSU/` at the tree root, `drivers/kernelsu` symlink, `drivers/Makefile`
   and `drivers/Kconfig` entries.
3. Applies **SUSFS** from `simonpunk/susfs4ksu`:
   `kernel_patches/fs/*` → `fs/`, `include/linux/*` → `include/linux/`,
   then `50_add_susfs_in_gki-<branch>.patch`. The branch is auto-detected from
   the kernel's `build.config.common` (`android12-5.10` →
   `gki-android12-5.10`).
   The builder pins SUSFS to the last revision that matches BakaSU's
   `sync-susfs` branch (`5a3af83e`). The next upstream revision expects an
   extra KernelSU hook that BakaSU does not expose on 5.10 yet, which would
   fail at link time. Pass `--susfs-ref latest` to try the branch tip.
   The SUSFS `preinit` hooks are compiled out with `-DKSU_NO_PREINIT` because
   BakaSU handles that path itself; this avoids undefined
   `ksu_setup_preinit_file`/`ksu_preinit_handle_post_execveat` symbols.
4. Generates the config exactly like LineageOS
   (`vendor/lineage/build/tasks/kernel.mk`): `gki_defconfig`, then
   `vendor/waipio_GKI.config`, `vendor/xiaomi_GKI.config`,
   `vendor/cupid_GKI.config`, `vendor/debugfs.config`, and finally
   `config/baksu_susfs.config`.
5. Builds `Image` with clang/lld and the LineageOS flags
   (`KCFLAGS=-D__ANDROID_COMMON_KERNEL__`, `TARGET_PRODUCT=cupid`).
6. Packages the AnyKernel3 zip and (optionally) a repacked `boot.img`.

LineageOS enables `CONFIG_LOCALVERSION_AUTO`, so its stock kernel release is
`<version>-gki-<kernel-commit>` (for example
`5.10.269-gki-geff4b40407a1`). A patched tree would normally get a `-dirty`
suffix, which breaks the vermagic of every vendor module. The builder therefore
disables `CONFIG_LOCALVERSION_AUTO` and hardcodes the exact detected suffix with
`CONFIG_LOCALVERSION` instead. Use `--from-device`/`--stock-boot` (or the exact
`--localversion` suffix) so the release matches the installed ROM.

The SUSFS patch currently applies to `lineage-24.0` with only line offsets
(no rejected hunks). If a future LineageOS merge breaks it, the script stops
and prints the rejected files; drop a fixup patch into `patches/` to adapt it
(see below).

---

## Updating LineageOS

Every LineageOS OTA writes a new `boot` partition and may bump the kernel
sublevel, so the custom kernel is overwritten. Update LineageOS first, then
rebuild and flash:

```bash
./build.sh --from-device --stock-boot /path/to/new-stock-boot.img --fresh
```

The builder uses the **tip** of the LineageOS kernel branch by default. If the
phone is not on the newest LineageOS build, the tip may contain a newer kernel
sublevel than the installed ROM. Either update the phone first, or build the
exact commit from the ROM's kernel manifest with `--kernel-ref <commit>`.

A kernel built for a different sublevel may still boot, but its release string
will not match the vendor modules (Wi-Fi/camera break). The builder warns when
it detects a mismatch against the phone/stock boot image.

---

## Troubleshooting

**Bootloop / reboots into fastboot**
: Do **not** keep flashing random images. Restore the stock boot first:

  ```bash
  fastboot flash boot /path/to/lineage-<build>-cupid-boot.img
  fastboot reboot
  ```

  The standalone `boot.img` for each cupid build is published by LineageOS at
  `https://mirrorbits.lineageos.org/full/cupid/<build-date>/boot.img`
  (also linked on the download page), so you do not need the whole OTA.

  Then capture the failed boot's kernel log. `/sys/fs/pstore` is root-only, so
  `adb root` first (LineageOS nightlies are userdebug builds):

  ```bash
  adb root
  adb shell ls -la /sys/fs/pstore/
  adb pull /sys/fs/pstore/console-ramoops-0 failed-boot.log
  ```

  If `adb root` is refused on your build, reboot into Lineage recovery, where
  adbd already runs as root, and read pstore there.

  Also try in fastboot: `fastboot oem last_kmsg` and
  `fastboot getvar current-slot`.

  A bootloop is most commonly caused by a kernel release/vermagic mismatch
  (vendor modules cannot load), an invalid boot image, or a kernel panic. The
  builder now refuses to package a kernel when it knows the release does not
  match the phone/stock boot.

**SUSFS patch fails**
: The upstream patch changed or LineageOS merged conflicting code. Run
  `./build.sh --patch-only --fresh` to stop after patching, check the `.rej`
  files listed in `dist/logs/build.log`, and add a fixup patch to `patches/`.
  Fixups are applied in filename order after the main SUSFS patch.

**`CONFIG_KSU` / `CONFIG_KSU_SUSFS` not enabled**
: Check `dist/kernel.config` and `dist/logs/build.log`. The config fragment is
  merged last; if a vendor fragment re-enables the tracepoint hook, the script
  aborts instead of producing a kernel without SUSFS.

**Out of memory during the build**
: Use `--jobs 4` and give WSL more memory (`.wslconfig` above). The final LTO
  link is the memory-hungry part.

**Compiler errors about unknown warning flags**
: You are probably on clang 16+. Install clang-12 or clang-14
  (`sudo ./build.sh --install-deps`, or `--clang /usr/bin/clang-14`).

**Builds but Wi-Fi/camera do not work**
: Kernel release mismatch. Compare `adb shell uname -r` with
  `dist/kernel-release.txt`; rebuild with `--from-device` or the exact
  `--localversion` suffix.

**AnyKernel3 says "new image larger than target"**
: Flash the repacked `boot.img` from fastboot instead; the AnyKernel3 check is
  conservative.

**Bootloop**
: Flash your stock `boot.img` (`fastboot flash boot stock-boot.img`) and
  rebuild with `--lto full`/without `--fast` to rule out config changes. The
  kernel does not touch `system`/`data`, so a boot rollback keeps your data.

**`source directory cannot contain spaces or colons`**
: Use the default work directory in `~/.cache`, or pass
  `--work-dir /home/<you>/cupid-build`.

---

## Notes and credits

* Kernel source: [LineageOS/android_kernel_xiaomi_sm8450](https://github.com/LineageOS/android_kernel_xiaomi_sm8450)
* Root: [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) (formerly ReSukiSU), GPL-2.0 kernel code
* SUSFS: [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) (mirrored on GitHub)
* Packaging: [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)
* Device facts: Xiaomi 12 `cupid`, SM8450, LineageOS kernel 5.10, A/B device
  (`boot_a`/`boot_b`), boot header v4, 4 KiB pages.

Flashing a custom kernel voids warranties, can trip device-integrity checks,
and may break OTA updates. Keep a stock boot image handy.
