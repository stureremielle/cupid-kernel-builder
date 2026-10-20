#!/usr/bin/env bash
#
# BakaSU (formerly ReSukiSU) + SUSFS kernel builder
# Device: Xiaomi 12 (cupid, SM8450) running LineageOS
#
# Builds the LineageOS 5.10 kernel from source with BakaSU and SUSFS
# built in, then packages the result as:
#   - a fastboot-flashable boot.img (if you supply the stock boot.img)
#   - an AnyKernel3 zip (for custom recoveries / kernel flash apps)
#   - the raw Image
#
# Run with --help for options.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/baka-cupid"

# Do not let a stale shell setting leak into the kernel release string.
unset LOCALVERSION

# ---------------------------------------------------------------------------
# Defaults (override with flags or environment variables)
# ---------------------------------------------------------------------------
DEVICE="${DEVICE:-cupid}"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-24.0}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_xiaomi_sm8450.git}"
KERNEL_REF="${KERNEL_REF:-}"
KSU_REPO="${KSU_REPO:-https://github.com/Baka-SU/BakaSU.git}"
KSU_REF="${KSU_REF:-sync-susfs}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-}"
SUSFS_REF="${SUSFS_REF:-}"
# Last SUSFS revision that matches BakaSU's sync-susfs branch. The next
# upstream change (2026-10-19 18:33) expects a KernelSU hook that this BakaSU
# branch does not expose on 5.10 yet (undefined my_setprocattr), so pin it.
SUSFS_PIN="5a3af83ef589eb1e19dc48550a9eb59fff1facdf"
LTO="${LTO:-thin}"                       # thin | full
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-}"
STOCK_BOOT="${STOCK_BOOT:-}"
WORK_DIR="${WORK_DIR:-$CACHE_BASE/work}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
CLANG="${CLANG:-}"

FROM_DEVICE=0
EXPECTED_RELEASE=""
PATCH_ONLY=0
NO_AK3=0
FAST=0
ALLOW_MISMATCH=0
INSTALL_DEPS=0
FRESH=0

KERNEL_DIR="$WORK_DIR/kernel"
OUT_DIR="$WORK_DIR/out"
SUSFS_DIR="$WORK_DIR/susfs"
AK3_DIR="$WORK_DIR/AnyKernel3"
LOG_DIR="$DIST_DIR/logs"
BUILD_LOG=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_END=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_END=''
fi

info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_END" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_END" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_END" "$*"; }
die()   { printf '%s[x]%s %s\n' "$C_RED" "$C_END" "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '\n%s[FAILED]%s build stopped (exit %s).\n' "$C_RED" "$C_END" "$rc" >&2
    if [ -n "$BUILD_LOG" ] && [ -f "$BUILD_LOG" ]; then
        printf 'Last log lines: %s\n' "$BUILD_LOG" >&2
        tail -n 30 "$BUILD_LOG" >&2
    fi
    exit "$rc"
}
trap on_error ERR

usage() {
    cat <<EOF
BakaSU + SUSFS kernel builder for the Xiaomi 12 (cupid) on LineageOS

Usage: ./build.sh [options]

Options:
  --lineage BRANCH     LineageOS kernel branch (default: $LINEAGE_BRANCH)
                       Examples: lineage-24.0, lineage-23.2, lineage-22.2
  --kernel-ref REF     Build this kernel commit/tag instead of the branch tip.
                       Use it when the phone is not on the newest LineageOS build.
  --ksu REF            BakaSU git tag/commit (default: $KSU_REF)
  --susfs BRANCH       susfs4ksu branch (default: auto-detect from the kernel)
  --susfs-ref REF      Pin SUSFS to a commit (default: known-good $SUSFS_PIN;
                       use 'latest' to track the branch tip)
  --lto MODE           thin (faster) or full (matches stock config) (default: $LTO)
  --localversion SUF   Exact kernel localversion suffix, e.g. '-gki-<kernel-sha>'.
                       Sets CONFIG_LOCALVERSION and disables AUTOVERSION.
                       Use --from-device/--stock-boot to detect it automatically.
                       Clears CONFIG_LOCALVERSION and hardcodes the value.
  --from-device        Read 'uname -r' from the connected phone via adb and
                       use its suffix as --localversion (recommended).
  --stock-boot FILE    Stock boot.img of the installed LineageOS build.
                       Its kernel release is detected automatically and a
                       flashable boot.img is produced at the end.
  --jobs N             Parallel build jobs (default: $JOBS)
  --work-dir DIR       Build directory (default: $WORK_DIR)
  --dist-dir DIR       Output directory (default: $DIST_DIR)
  --clang PATH         clang to use (default: auto-detect clang-12..15)
  --fast               Disable CONFIG_DEBUG_INFO (faster, smaller build)
  --allow-release-mismatch
                       Package the kernel even if its release does not match the
                       phone/stock boot (not recommended: vendor modules fail).
  --patch-only         Stop after patching the kernel sources
  --no-ak3             Do not build the AnyKernel3 zip
  --fresh              Delete the work directory before starting
  --install-deps       Install build dependencies with apt and exit
  -h, --help           Show this help

Environment variables: LINEAGE_BRANCH, KERNEL_REF, KSU_REF, SUSFS_BRANCH,
SUSFS_REF, LTO, JOBS, KERNEL_LOCALVERSION, STOCK_BOOT, WORK_DIR, DIST_DIR,
CLANG

Examples:
  ./build.sh --install-deps
  ./build.sh --from-device
  ./build.sh --lineage lineage-23.2 --stock-boot ~/lineage-cupid-boot.img
  ./build.sh --localversion '-gki-geff4b40407a1' --jobs 6
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lineage)        LINEAGE_BRANCH="$2"; shift 2 ;;
        --kernel-ref)     KERNEL_REF="$2"; shift 2 ;;
        --ksu)            KSU_REF="$2"; shift 2 ;;
        --susfs)          SUSFS_BRANCH="$2"; shift 2 ;;
        --susfs-ref)      SUSFS_REF="$2"; shift 2 ;;
        --lto)            LTO="$2"; shift 2 ;;
        --localversion)   KERNEL_LOCALVERSION="$2"; shift 2 ;;
        --from-device)    FROM_DEVICE=1; shift ;;
        --stock-boot)     STOCK_BOOT="$2"; shift 2 ;;
        --jobs)           JOBS="$2"; shift 2 ;;
        --work-dir)       WORK_DIR="$2"; KERNEL_DIR="$WORK_DIR/kernel"; OUT_DIR="$WORK_DIR/out"; shift 2 ;;
        --dist-dir)       DIST_DIR="$2"; shift 2 ;;
        --clang)          CLANG="$2"; shift 2 ;;
        --fast)           FAST=1; shift ;;
        --allow-release-mismatch) ALLOW_MISMATCH=1; shift ;;
        --patch-only)     PATCH_ONLY=1; shift ;;
        --no-ak3)         NO_AK3=1; shift ;;
        --fresh)          FRESH=1; shift ;;
        --install-deps)   INSTALL_DEPS=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

case "$WORK_DIR" in
    /*) ;;
    *) WORK_DIR="$SCRIPT_DIR/$WORK_DIR" ;;
esac
case "$DIST_DIR" in
    /*) ;;
    *) DIST_DIR="$SCRIPT_DIR/$DIST_DIR" ;;
esac

KERNEL_DIR="$WORK_DIR/kernel"
OUT_DIR="$WORK_DIR/out"
SUSFS_DIR="$WORK_DIR/susfs"
AK3_DIR="$WORK_DIR/AnyKernel3"
LOG_DIR="$DIST_DIR/logs"
BUILD_LOG="$LOG_DIR/build.log"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || die "This must run on Linux (WSL2 Ubuntu is fine). On Windows, see README.md."

case "$WORK_DIR" in
    *" "*|*:*)
        die "WORK_DIR contains a space or colon ('$WORK_DIR'). The kernel Makefile cannot handle that.
     Pick another location, e.g. --work-dir ~/cupid-build" ;;
esac

case "$LTO" in thin|full) ;; *) die "--lto must be 'thin' or 'full'" ;; esac

mkdir -p "$WORK_DIR" "$DIST_DIR" "$LOG_DIR"
: > "$BUILD_LOG"

if [ "$INSTALL_DEPS" = 1 ]; then
    exec bash "$SCRIPT_DIR/scripts/install-deps.sh"
fi

if [ "$FRESH" = 1 ]; then
    info "Removing $WORK_DIR"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
fi

needed=(git make patch curl tar zip unzip python3 bc bison flex cpio perl rsync gcc g++ strings)
missing=()
for c in "${needed[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
    die "Missing host tools: ${missing[*]}
     Run './build.sh --install-deps' (Debian/Ubuntu/WSL) first."
fi

# ---------------------------------------------------------------------------
# Toolchain (prefer the clang version LineageOS uses: r416183b == clang 12)
# ---------------------------------------------------------------------------
setup_toolchain() {
    local tc_bin="$WORK_DIR/toolchain/bin"
    mkdir -p "$tc_bin"

    local clang_bin="" cc
    if [ -n "$CLANG" ]; then
        clang_bin="$(command -v "$CLANG" || true)"
        [ -n "$clang_bin" ] || die "clang not found: $CLANG"
    else
        for v in 12 13 14 15; do
            if command -v "clang-$v" >/dev/null 2>&1; then
                clang_bin="$(command -v "clang-$v")"
                break
            fi
        done
        if [ -z "$clang_bin" ] && command -v clang >/dev/null 2>&1; then
            clang_bin="$(command -v clang)"
        fi
    fi

    [ -n "$clang_bin" ] || die "No clang found. Run './build.sh --install-deps'."

    local major
    major="$("$clang_bin" --version | sed -nE 's/.*clang version ([0-9]+).*/\1/p' | head -n1)"
    [ -n "$major" ] || die "Could not determine clang version from $clang_bin"
    if [ "$major" -lt 12 ]; then
        die "clang $major is too old. clang 12+ is required."
    fi
    if [ "$major" -gt 15 ]; then
        warn "clang $major is newer than the LineageOS toolchain (clang 12)."
        warn "If the build fails on a warning, install clang-12/14 instead."
    fi

    # LineageOS builds this kernel with clang-r416183b (clang 12) and lld.
    # Use tools from the SAME LLVM major version: clang 14 + lld 12 makes
    # CONFIG_LTO_CLANG silently unavailable, dropping LTO and CFI.
    local dir base found cand
    dir="$(dirname "$clang_bin")"
    for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
        base="$(basename "$t")"
        found=""
        for cand in \
            "$dir/$base-$major" \
            "$(command -v "$base-$major" 2>/dev/null || true)" \
            "$dir/$base" \
            "$(command -v "$base" 2>/dev/null || true)"
        do
            if [ -n "$cand" ] && [ -x "$cand" ]; then
                found="$cand"
                break
            fi
        done
        if [ -n "$found" ]; then
            ln -sfn "$found" "$tc_bin/$base"
        fi
    done

    export PATH="$tc_bin:$PATH"
    [ -x "$tc_bin/clang" ] || die "clang not available in toolchain dir"
    [ -x "$tc_bin/ld.lld" ] || die "ld.lld not found. Install lld (e.g. lld-$major)."

    local lld_major
    lld_major="$(ld.lld --version 2>/dev/null | sed -nE 's/.*LLD ([0-9]+).*/\1/p' | head -n1)"
    if [ -n "$lld_major" ] && [ "$lld_major" != "$major" ]; then
        warn "clang is $major but ld.lld is $lld_major."
        warn "LTO/CFI will be unavailable. Install lld-$major and re-run,"
        warn "or use --clang /usr/bin/clang-$lld_major."
    fi

    info "Toolchain: $(clang --version | head -n1)"
    info "Linker:    $(ld.lld --version | head -n1)"
}
setup_toolchain

# ---------------------------------------------------------------------------
# Read the stock kernel release, if we can
# ---------------------------------------------------------------------------
strip_version() { sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+//'; }

if [ -n "$KERNEL_LOCALVERSION" ]; then
    info "Using supplied kernel localversion: $KERNEL_LOCALVERSION"
elif [ "$FROM_DEVICE" = 1 ]; then
    command -v adb >/dev/null 2>&1 || die "--from-device needs adb in PATH"
    rel="$(adb shell uname -r 2>/dev/null | tr -d '\r' | head -n1 || true)"
    [ -n "$rel" ] || die "Could not read 'uname -r' from the phone. Is it connected and authorized?"
    EXPECTED_RELEASE="$rel"
    KERNEL_LOCALVERSION="$(printf '%s' "$rel" | strip_version)"
    info "Phone kernel release: $rel"
    info "Using localversion:   $KERNEL_LOCALVERSION"
elif [ -n "$STOCK_BOOT" ]; then
    [ -f "$STOCK_BOOT" ] || die "Stock boot image not found: $STOCK_BOOT"
    rel="$(strings -a "$STOCK_BOOT" 2>/dev/null | grep -m1 -oE 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^ ]*' | awk '{print $3}' || true)"
    if [ -n "$rel" ]; then
        EXPECTED_RELEASE="$rel"
        KERNEL_LOCALVERSION="$(printf '%s' "$rel" | strip_version)"
        info "Stock boot kernel release: $rel"
        info "Using localversion:        $KERNEL_LOCALVERSION"
    else
        warn "Could not read a kernel release from $STOCK_BOOT."
        warn "Falling back to CONFIG_LOCALVERSION=-gki; vendor modules may not match."
    fi
fi

# ---------------------------------------------------------------------------
# Kernel source
# ---------------------------------------------------------------------------
info "LineageOS kernel branch: $LINEAGE_BRANCH"
if [ -n "$KERNEL_REF" ]; then
    info "Kernel ref requested:    $KERNEL_REF"
else
    warn "Building the tip of $LINEAGE_BRANCH. Update LineageOS first, or pass"
    warn "--kernel-ref <commit> if the phone is not on the newest build."
fi

if [ -d "$KERNEL_DIR/.git" ]; then
    info "Updating kernel source in $KERNEL_DIR"
    git -C "$KERNEL_DIR" fetch --depth=1 origin "$LINEAGE_BRANCH" >>"$BUILD_LOG" 2>&1
    git -C "$KERNEL_DIR" checkout -q -f FETCH_HEAD
    git -C "$KERNEL_DIR" reset -q --hard FETCH_HEAD
    git -C "$KERNEL_DIR" clean -qfdx
else
    info "Cloning kernel source (shallow) ..."
    rm -rf "$KERNEL_DIR"
    git clone --depth=1 --branch "$LINEAGE_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR" >>"$BUILD_LOG" 2>&1
fi

if [ -n "$KERNEL_REF" ]; then
    info "Checking out kernel ref $KERNEL_REF ..."
    if ! git -C "$KERNEL_DIR" fetch --depth=1 origin "$KERNEL_REF" >>"$BUILD_LOG" 2>&1; then
        git -C "$KERNEL_DIR" fetch origin "$KERNEL_REF" >>"$BUILD_LOG" 2>&1
    fi
    git -C "$KERNEL_DIR" checkout -q -f FETCH_HEAD
    git -C "$KERNEL_DIR" reset -q --hard FETCH_HEAD
    git -C "$KERNEL_DIR" clean -qfdx
fi

KVER="$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v"."p"."s}' "$KERNEL_DIR/Makefile")"
[ -n "$KVER" ] || die "Could not determine kernel version from $KERNEL_DIR/Makefile"
ok "Kernel source ready: $KVER"

# ---------------------------------------------------------------------------
# Auto-detect the matching SUSFS branch from the kernel's build.config
# ---------------------------------------------------------------------------
if [ -z "$SUSFS_BRANCH" ]; then
    kbranch="$(grep -m1 '^BRANCH=' "$KERNEL_DIR/build.config.common" 2>/dev/null | cut -d= -f2- || true)"
    if [ -n "$kbranch" ]; then
        SUSFS_BRANCH="gki-$kbranch"
    else
        SUSFS_BRANCH="gki-android12-5.10"
    fi
fi
if [ "$SUSFS_REF" = "latest" ]; then
    SUSFS_REF=""
fi
if [ -z "$SUSFS_REF" ] && [ "$SUSFS_BRANCH" = "gki-android12-5.10" ]; then
    SUSFS_REF="$SUSFS_PIN"
    info "SUSFS ref:    $SUSFS_REF (known-good; use --susfs-ref latest to track the branch)"
fi
info "SUSFS branch: $SUSFS_BRANCH"

# ---------------------------------------------------------------------------
# Integrate BakaSU (formerly ReSukiSU)
# ---------------------------------------------------------------------------
KSU_COMMIT=""
integrate_baksu() {
    info "Integrating BakaSU ($KSU_REF) ..."
    rm -rf "$KERNEL_DIR/KernelSU"
    git clone "$KSU_REPO" "$KERNEL_DIR/KernelSU" >>"$BUILD_LOG" 2>&1
    git -C "$KERNEL_DIR/KernelSU" checkout -q "$KSU_REF"
    KSU_COMMIT="$(git -C "$KERNEL_DIR/KernelSU" rev-parse --short=12 HEAD)"

    # Same layout as BakaSU's own kernel/setup.sh
    ln -sfn ../KernelSU/kernel "$KERNEL_DIR/drivers/kernelsu"

    if ! grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile"; then
        printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
    fi
    if ! grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig"; then
        printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL_DIR/drivers/Kconfig"
    fi
    ok "BakaSU integrated: $(git -C "$KERNEL_DIR/KernelSU" describe --tags --always 2>/dev/null || echo "$KSU_REF")"
}
integrate_baksu

# ---------------------------------------------------------------------------
# Integrate SUSFS
# ---------------------------------------------------------------------------
apply_susfs() {
    info "Integrating SUSFS ($SUSFS_BRANCH) ..."
    rm -rf "$SUSFS_DIR"
    git clone --depth=1 --single-branch --branch "$SUSFS_BRANCH" "$SUSFS_REPO" "$SUSFS_DIR" >>"$BUILD_LOG" 2>&1
    if [ -n "$SUSFS_REF" ]; then
        info "Checking out SUSFS ref $SUSFS_REF ..."
        if ! git -C "$SUSFS_DIR" fetch --depth=1 origin "$SUSFS_REF" >>"$BUILD_LOG" 2>&1; then
            git -C "$SUSFS_DIR" fetch origin "$SUSFS_REF" >>"$BUILD_LOG" 2>&1
        fi
        git -C "$SUSFS_DIR" checkout -q FETCH_HEAD
    fi

    local patch_file="$SUSFS_DIR/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
    [ -f "$patch_file" ] || die "SUSFS patch not found: $patch_file"

    cp -a "$SUSFS_DIR/kernel_patches/fs/." "$KERNEL_DIR/fs/"
    cp -a "$SUSFS_DIR/kernel_patches/include/linux/." "$KERNEL_DIR/include/linux/"

    # The vendor tree contains a committed drivers/.../fts_lib/Makefile.rej.
    # Remember which reject files already exist so we only report new ones.
    local before_rej="$WORK_DIR/rejects-before.txt"
    find "$KERNEL_DIR" -name '*.rej' -not -path '*/.git/*' | sort > "$before_rej"

    local rc=0
    set +e
    ( cd "$KERNEL_DIR" && patch -p1 --forward -F3 --batch --no-backup-if-mismatch < "$patch_file" ) \
        >>"$BUILD_LOG" 2>&1
    rc=$?
    set -e

    local rejects
    rejects="$(find "$KERNEL_DIR" -name '*.rej' -not -path '*/.git/*' | sort | comm -13 "$before_rej" - || true)"
    if [ "$rc" -ne 0 ] || [ -n "$rejects" ]; then
        printf '\n'
        warn "SUSFS patch did not apply cleanly."
        if [ -n "$rejects" ]; then
            printf 'Rejected files:\n%s\n' "$rejects"
        fi
        printf 'Patch log: %s\n' "$BUILD_LOG"
        printf 'Tip: update to a newer susfs4ksu branch (--susfs ...) or add a fixup patch to patches/.\n'
        exit 1
    fi
    ok "SUSFS applied ($(grep -m1 SUSFS_VERSION "$KERNEL_DIR/include/linux/susfs.h" | cut -d'"' -f2))"

    # Optional local fixups, applied in filename order
    if compgen -G "$SCRIPT_DIR/patches/*.patch" >/dev/null; then
        for p in "$SCRIPT_DIR"/patches/*.patch; do
            info "Applying fixup $(basename "$p")"
            ( cd "$KERNEL_DIR" && patch -p1 --forward -F3 --batch --no-backup-if-mismatch < "$p" ) >>"$BUILD_LOG" 2>&1
        done
    fi
}
apply_susfs

if [ "$PATCH_ONLY" = 1 ]; then
    ok "Sources patched. Stopping because --patch-only was given."
    exit 0
fi

# ---------------------------------------------------------------------------
# Kernel configuration (exactly what LineageOS' build/tasks/kernel.mk does)
# ---------------------------------------------------------------------------
configure_kernel() {
    info "Generating kernel config ..."
    local defconfig_dir="$KERNEL_DIR/arch/arm64/configs"
    local fragments=(
        "vendor/waipio_GKI.config"
        "vendor/xiaomi_GKI.config"
        "vendor/${DEVICE}_GKI.config"
        "vendor/debugfs.config"
    )

    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
    cp "$defconfig_dir/gki_defconfig" "$OUT_DIR/.config"

    make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 \
        CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip \
        CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
        KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -DKSU_NO_PREINIT" TARGET_PRODUCT="$DEVICE" \
        olddefconfig >>"$BUILD_LOG" 2>&1

    local frag
    for frag in "${fragments[@]}"; do
        [ -f "$defconfig_dir/$frag" ] || die "Missing kernel config fragment: $frag"
        ( cd "$OUT_DIR" && "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
            "$OUT_DIR/.config" "$defconfig_dir/$frag" ) >>"$BUILD_LOG" 2>&1
        make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 \
            CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
            OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip \
            CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
            KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -DKSU_NO_PREINIT" TARGET_PRODUCT="$DEVICE" \
            olddefconfig >>"$BUILD_LOG" 2>&1
    done

    # BakaSU + SUSFS options
    ( cd "$OUT_DIR" && "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
        "$OUT_DIR/.config" "$SCRIPT_DIR/config/baksu_susfs.config" ) >>"$BUILD_LOG" 2>&1

    if [ "$FAST" = 1 ]; then
        "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d DEBUG_INFO -d DEBUG_INFO_DWARF4
    fi

    # Same LTO handling as LineageOS' KERNEL_LTO
    if [ "$LTO" = "thin" ]; then
        "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
            -e LTO_CLANG -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL -e THINLTO
    else
        "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
            -e LTO_CLANG -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL -d THINLTO
    fi

    # The source tree is always dirty after patching. With
    # CONFIG_LOCALVERSION_AUTO=y the kernel release becomes
    # "5.10.269-gki-<sha>-dirty", which does not match the vendor modules'
    # vermagic. Disable AUTO and hardcode the exact stock suffix instead.
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LOCALVERSION_AUTO
    if [ -n "$KERNEL_LOCALVERSION" ]; then
        "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
            --set-str LOCALVERSION "$KERNEL_LOCALVERSION"
    fi

    make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 \
        CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip \
        CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
        KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -DKSU_NO_PREINIT" TARGET_PRODUCT="$DEVICE" \
        olddefconfig >>"$BUILD_LOG" 2>&1

    # Sanity checks
    grep -q '^CONFIG_KSU=y'              "$OUT_DIR/.config" || die "CONFIG_KSU was not enabled. See $BUILD_LOG"
    grep -q '^CONFIG_KSU_SUSFS=y'        "$OUT_DIR/.config" || die "CONFIG_KSU_SUSFS was not enabled. See $BUILD_LOG"
    grep -q '^CONFIG_KSU_SUSFS_SUS_PATH=y' "$OUT_DIR/.config" || die "SUS_PATH was not enabled. See $BUILD_LOG"

    # Stock LineageOS builds this kernel with LTO + CFI. If they silently get
    # dropped (usually a clang/lld version mismatch), the result deviates from
    # the stock ABI and is not something we want to flash.
    # LTO/CFI are what stock uses, but they are not required for vendor modules
    # to load (neither appears in vermagic). Warn instead of blocking the build
    # so a toolchain mismatch cannot stop you from getting a bootable kernel.
    if [ "$LTO" = "full" ]; then
        grep -q '^CONFIG_LTO_CLANG_FULL=y' "$OUT_DIR/.config" \
            || warn "Full LTO did not enable (clang/lld mismatch?). Continuing without LTO."
    else
        grep -q '^CONFIG_LTO_CLANG_THIN=y' "$OUT_DIR/.config" \
            || warn "Thin LTO did not enable (clang/lld mismatch?). Continuing without LTO."
    fi
    grep -q '^CONFIG_CFI_CLANG=y' "$OUT_DIR/.config" \
        || warn "CONFIG_CFI_CLANG did not enable. Continuing without CFI."

    # Never allow the -dirty / duplicate-hash localversion regression again.
    if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "$OUT_DIR/.config"; then
        die "CONFIG_LOCALVERSION_AUTO is still enabled; the release string would not match the ROM."
    fi
    if [ -n "$KERNEL_LOCALVERSION" ]; then
        grep -qF "CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\"" "$OUT_DIR/.config" \
            || die "CONFIG_LOCALVERSION was not set to '$KERNEL_LOCALVERSION'. See $BUILD_LOG"
    fi
    if grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y' "$OUT_DIR/.config"; then
        die "KSU_TRACEPOINT_HOOK is still enabled; the SUSFS hook mode was not selected."
    fi
    if grep -q '^CONFIG_KSU_MANUAL_HOOK=y' "$OUT_DIR/.config"; then
        die "KSU_MANUAL_HOOK is enabled; the SUSFS hook mode was not selected."
    fi

    ok "Config ready (CONFIG_KSU=y, CONFIG_KSU_SUSFS=y, LTO=$LTO)"
}
configure_kernel

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
info "Building Image with $JOBS jobs (this can take a while) ..."
MAKE_ARGS=(
    -C "$KERNEL_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip
    CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
    LLVM_IAS=1 KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -DKSU_NO_PREINIT" TARGET_PRODUCT="$DEVICE"
    # Set but empty: suppresses the "+" that setlocalversion adds to dirty,
    # untagged trees. The actual suffix lives in CONFIG_LOCALVERSION.
    LOCALVERSION=
)

# Export, not just pass on the make command line: scripts/setlocalversion reads
# it from the environment and uses "set but empty" to suppress the "+" suffix.
export LOCALVERSION=""

set +e
make "${MAKE_ARGS[@]}" -j"$JOBS" Image 2>&1 | tee -a "$BUILD_LOG"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" -eq 0 ] || die "Kernel build failed. See $BUILD_LOG"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Kernel Image not found at $IMAGE"

RELEASE="$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || echo unknown)"
ok "Kernel built: $RELEASE ($(du -h "$IMAGE" | cut -f1))"

if [ -n "$EXPECTED_RELEASE" ] && [ "$RELEASE" != "$EXPECTED_RELEASE" ]; then
    printf '\n'
    warn "KERNEL RELEASE MISMATCH"
    warn "  built:    $RELEASE"
    warn "  expected: $EXPECTED_RELEASE"
    warn "Vendor modules (Wi-Fi, camera, ...) will probably refuse to load."
    warn "Rebuild with --kernel-ref <kernel commit of the installed Lineage build>,"
    warn "or update LineageOS to the newest build first."
    printf '\n'
    if [ "$ALLOW_MISMATCH" = 1 ]; then
        warn "Continuing because --allow-release-mismatch was given."
    else
        die "Refusing to package a kernel whose vermagic will not match the ROM.
     Pass --allow-release-mismatch only if you know what you are doing."
    fi
elif [ -z "$EXPECTED_RELEASE" ]; then
    warn "Kernel release is $RELEASE."
    warn "Compare it with 'adb shell uname -r' before flashing; they must match."
fi

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M)"
BASE_NAME="BakaSU-SUSFS-${DEVICE}-${LINEAGE_BRANCH#lineage-}-${STAMP}"

cp -f "$IMAGE" "$DIST_DIR/Image"
cp -f "$OUT_DIR/.config" "$DIST_DIR/kernel.config"
{
    echo "device=$DEVICE"
    echo "lineage_branch=$LINEAGE_BRANCH"
    echo "kernel_ref=${KERNEL_REF:-tip}"
    echo "kernel_version=$KVER"
    echo "kernel_release=$RELEASE"
    echo "baksu=$KSU_REF"
    echo "baksu_commit=$KSU_COMMIT"
    echo "susfs_branch=$SUSFS_BRANCH"
    echo "susfs_ref=${SUSFS_REF:-latest}"
    echo "lto=$LTO"
    echo "image=$(du -h "$IMAGE" | cut -f1)"
    echo "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DIST_DIR/kernel-release.txt"

# AnyKernel3 zip (recovery / kernel-flasher app)
AK3_ZIP=""
if [ "$NO_AK3" = 0 ]; then
    info "Packaging AnyKernel3 zip ..."
    rm -rf "$AK3_DIR"
    git clone --depth=1 -q https://github.com/osm0sis/AnyKernel3.git "$AK3_DIR" >>"$BUILD_LOG" 2>&1
    rm -rf "$AK3_DIR/.git" "$AK3_DIR"/Image* "$AK3_DIR"/zImage*
    cp -f "$IMAGE" "$AK3_DIR/Image"
    cp -f "$SCRIPT_DIR/anykernel/anykernel.sh" "$AK3_DIR/anykernel.sh"
    AK3_ZIP="$DIST_DIR/${BASE_NAME}.zip"
    ( cd "$AK3_DIR" && zip -r9 "$AK3_ZIP" . -x '*.git*' >/dev/null )
    ok "AnyKernel3 zip: $AK3_ZIP"
fi

# Boot image (fastboot)
BOOT_IMG=""
if [ -n "$STOCK_BOOT" ]; then
    info "Repacking boot.img (replacing the kernel) ..."
    command -v python3 >/dev/null 2>&1 || die "python3 is required to repack boot.img"
    BOOT_IMG="$DIST_DIR/${BASE_NAME}-boot.img"
    python3 "$SCRIPT_DIR/scripts/repack_boot.py" \
        --stock "$STOCK_BOOT" --image "$IMAGE" --out "$BOOT_IMG"
    ok "Boot image: $BOOT_IMG"
fi

# Small human-readable summary next to the artifacts
cat > "$DIST_DIR/FLASH.txt" <<EOF
BakaSU + SUSFS kernel for Xiaomi 12 (cupid)
Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Kernel release: $RELEASE
Expected release (phone/stock boot): ${EXPECTED_RELEASE:-not detected}
LineageOS branch: $LINEAGE_BRANCH
BakaSU: $KSU_REF ($KSU_COMMIT)
SUSFS: $SUSFS_BRANCH ($(grep -m1 SUSFS_VERSION "$KERNEL_DIR/include/linux/susfs.h" | cut -d'"' -f2))

IMPORTANT: kernel modules (Wi-Fi, camera, ...) only load if the kernel release
matches the LineageOS build that is installed on the phone. Check with:
    adb shell uname -r
Expected here: $RELEASE

Fastboot (recommended)
----------------------
If you have a boot.img in this folder:
    adb reboot bootloader
    fastboot flash boot ${BASE_NAME}-boot.img
    fastboot reboot
Safety net: keep the original LineageOS boot.img and flash it the same way
to roll back.

Recovery / kernel flasher app
-----------------------------
Flash ${BASE_NAME}.zip in a custom recovery (TWRP/OrangeFox) or with a
kernel flasher app that supports AnyKernel3.

After booting
-------------
Install the BakaSU manager APK from:
    https://github.com/Baka-SU/BakaSU/releases
Open it, grant root, and use the built-in SUSFS page to enable the features
you need. If you want the CLI, install the susfs4ksu module as well.
EOF

printf '\n'
ok "Done."
printf '  Image:          %s\n' "$DIST_DIR/Image"
if [ -n "$AK3_ZIP" ]; then
    printf '  AnyKernel3:     %s\n' "$AK3_ZIP"
fi
if [ -n "$BOOT_IMG" ]; then
    printf '  boot.img:       %s\n' "$BOOT_IMG"
fi
printf '  Kernel release: %s\n' "$RELEASE"
printf '  Config:         %s\n' "$DIST_DIR/kernel.config"
printf '  Log:            %s\n' "$BUILD_LOG"
printf '  Flash notes:    %s\n' "$DIST_DIR/FLASH.txt"
printf '\n'
warn "Verify 'adb shell uname -r' matches $RELEASE before flashing; otherwise Wi-Fi and other modules may not load."
