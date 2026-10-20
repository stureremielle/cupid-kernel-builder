### AnyKernel3 Ramdisk Mod Script
## BakaSU + SUSFS for Xiaomi 12 (cupid)

### AnyKernel setup
properties() { '
kernel.string=BakaSU + SUSFS (LineageOS / Xiaomi 12)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=cupid
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
# cupid is an A/B device: boot_a / boot_b
# Use the partition name so AK3 can find /dev/block/by-name or bootdevice/by-name.
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# Replace only the kernel; keep the stock ramdisk/DTB untouched.
split_boot;
flash_boot;
## end boot install
