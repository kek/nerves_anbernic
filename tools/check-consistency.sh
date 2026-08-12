#!/bin/bash
#
# Assert that the five files describing the image layout agree with each
# other.
#
#   fwup_include/fwup-common.conf   partition offsets and sizes
#   uboot/uboot.defconfig           where U-Boot keeps its environment
#   uboot/uboot.env                 which partition each slot boots
#   rootfs_overlay/etc/fw_env.config  where Elixir reads that environment
#   rootfs_overlay/boot/extlinux/*  which partition each slot mounts as root
#   rootfs_overlay/etc/erlinit.config where the app data partition is mounted
#
# None of these disagreements produce a build error. They produce a device
# that boots the wrong rootfs, mounts nothing at /root, or silently loses its
# firmware metadata -- so they are worth asserting mechanically.
#
# Pure shell and awk, no Docker, no network.
#
set -euo pipefail

cd "$(dirname "$0")/.."

rc=0
ok()   { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; rc=1; }

val() { # val <file> <define-name>
    awk -v n="$2" '$0 ~ "^define\\("n"," {
        line=$0
        sub(/^define\([^,]*,[[:space:]]*/, "", line)
        sub(/\).*$/, "", line)
        gsub(/"/, "", line)
        print line
        exit
    }' "$1"
}

COMMON=fwup_include/fwup-common.conf

UBOOT_OFFSET=$(val $COMMON UBOOT_OFFSET)
UBOOT_COUNT=$(val $COMMON UBOOT_COUNT)
ENV_OFFSET=$(val $COMMON UBOOT_ENV_OFFSET)
ENV_COUNT=$(val $COMMON UBOOT_ENV_COUNT)
ROOTFS_A_OFFSET=$(val $COMMON ROOTFS_A_PART_OFFSET)
ROOTFS_A_COUNT=$(val $COMMON ROOTFS_A_PART_COUNT)
APP_DEVPATH=$(val $COMMON NERVES_FW_APPLICATION_PART0_DEVPATH)
APP_FSTYPE=$(val $COMMON NERVES_FW_APPLICATION_PART0_FSTYPE)
APP_TARGET=$(val $COMMON NERVES_FW_APPLICATION_PART0_TARGET)

echo "==> image layout"

# U-Boot must not run into its own environment block.
if [ $((UBOOT_OFFSET + UBOOT_COUNT)) -le "$ENV_OFFSET" ]; then
    ok "U-Boot ($UBOOT_OFFSET..$((UBOOT_OFFSET + UBOOT_COUNT))) ends at or before env ($ENV_OFFSET)"
else
    fail "U-Boot overruns its environment block"
fi

# The environment must not run into rootfs A.
if [ $((ENV_OFFSET + ENV_COUNT)) -le "$ROOTFS_A_OFFSET" ]; then
    ok "env ends at or before rootfs A ($ROOTFS_A_OFFSET)"
else
    fail "U-Boot environment overlaps rootfs A"
fi

# Partitions should sit on 1 MiB boundaries (2048 sectors of 512 bytes).
for pair in "ROOTFS_A_PART_OFFSET:$ROOTFS_A_OFFSET" "ROOTFS_A_PART_COUNT:$ROOTFS_A_COUNT"; do
    name=${pair%%:*}; v=${pair#*:}
    if [ $((v % 2048)) -eq 0 ]; then ok "$name ($v) is 1 MiB aligned"
    else fail "$name ($v) is not 1 MiB aligned"; fi
done

echo "==> U-Boot environment location agrees in three places"

# fwup counts 512-byte sectors; U-Boot and fw_env use byte offsets.
want_off=$(printf '0x%x' $((ENV_OFFSET * 512)))
want_size=$(printf '0x%x' $((ENV_COUNT * 512)))

uboot_off=$(awk -F= '/^CONFIG_ENV_OFFSET=/ {print tolower($2)}' uboot/uboot.defconfig)
uboot_size=$(awk -F= '/^CONFIG_ENV_SIZE=/ {print tolower($2)}' uboot/uboot.defconfig)

[ "$uboot_off" = "$want_off" ] \
    && ok "CONFIG_ENV_OFFSET=$uboot_off matches sector $ENV_OFFSET" \
    || fail "CONFIG_ENV_OFFSET=$uboot_off but fwup puts it at $want_off"
[ "$uboot_size" = "$want_size" ] \
    && ok "CONFIG_ENV_SIZE=$uboot_size matches $ENV_COUNT sectors" \
    || fail "CONFIG_ENV_SIZE=$uboot_size but fwup reserves $want_size"

# fw_env.config: "<device> <offset> <size>", ignoring comments.
read -r fwenv_dev fwenv_off fwenv_size < <(
    grep -vE '^[[:space:]]*(#|$)' rootfs_overlay/etc/fw_env.config | head -1
)
[ "$(echo "$fwenv_off" | tr 'A-F' 'a-f')" = "$want_off" ] \
    && ok "fw_env.config offset $fwenv_off matches" \
    || fail "fw_env.config offset $fwenv_off but expected $want_off"
[ "$(echo "$fwenv_size" | tr 'A-F' 'a-f')" = "$want_size" ] \
    && ok "fw_env.config size $fwenv_size matches" \
    || fail "fw_env.config size $fwenv_size but expected $want_size"

echo "==> partition numbering"

# fwup's mbr slots are 0-based, Linux device names are 1-based, and slot 0 is
# intentionally empty. So slot 1 -> p2 (rootfs A), 2 -> p3 (B), 3 -> p4 (app).
for spec in "extlinux-a.conf:2" "extlinux-b.conf:3"; do
    f=rootfs_overlay/boot/extlinux/${spec%%:*}; want=p${spec#*:}
    if grep -q "root=/dev/mmcblk0${want} " "$f"; then
        ok "${spec%%:*} boots /dev/mmcblk0${want}"
    else
        fail "${spec%%:*} does not set root=/dev/mmcblk0${want} (got: $(grep -o 'root=[^ ]*' "$f" | head -1))"
    fi
done

# uboot.env selects the partition sysboot reads extlinux.conf from.
grep -q 'setenv uenv_part 2' uboot/uboot.env \
    && ok "uboot.env maps slot a to partition 2" \
    || fail "uboot.env does not map slot a to partition 2"
grep -q 'setenv uenv_part 3' uboot/uboot.env \
    && ok "uboot.env maps slot b to partition 3" \
    || fail "uboot.env does not map slot b to partition 3"

echo "==> application partition"

# erlinit mounts it; fwup declares it. A mismatch costs shell history and
# leaves the app writing to a tmpfs that vanishes on reboot.
erlinit_mount=$(grep -oE '^-m [^[:space:]]+' rootfs_overlay/etc/erlinit.config | awk '{print $2}')
want_mount="${APP_DEVPATH}:${APP_TARGET}:${APP_FSTYPE}:nodev:"
[ "$erlinit_mount" = "$want_mount" ] \
    && ok "erlinit mounts $erlinit_mount" \
    || fail "erlinit mounts '$erlinit_mount' but fwup declares '$want_mount'"

# The DTB named in extlinux must be the one the kernel build installs, which
# Buildroot derives from the DTS filename.
dts_base=$(basename linux/sun50i-h700-anbernic-rg40xx-v.dts .dts)
for f in rootfs_overlay/boot/extlinux/extlinux-a.conf rootfs_overlay/boot/extlinux/extlinux-b.conf; do
    if grep -q "fdt /boot/${dts_base}.dtb" "$f"; then
        ok "$(basename "$f") loads ${dts_base}.dtb"
    else
        fail "$(basename "$f") does not load /boot/${dts_base}.dtb"
    fi
done

# Buildroot builds the DTB named by BR2_LINUX_KERNEL_CUSTOM_DTS_PATH.
grep -q "linux/${dts_base}.dts" nerves_defconfig \
    && ok "nerves_defconfig points at ${dts_base}.dts" \
    || fail "nerves_defconfig does not reference linux/${dts_base}.dts"

echo "==> panel firmware"

# The generic panel driver builds a firmware filename out of the first
# compatible string in the panel node: panels/<compatible>.panel. Nothing
# checks this at build time, and getting it wrong is close to undebuggable on
# device -- the panel simply never initialises, with no error, because
# request_firmware() failing is not fatal to the rest of the pipeline. So
# assert the two spellings match here, where it costs nothing.
# Anchor on the generic fallback rather than on "anbernic," alone -- the board
# node's own compatible starts with "anbernic,rg40xx-v" and would otherwise
# match first.
panel_compat=$(awk '/panel-mipi-dpi-spi/ && /compatible/ {
        match($0, /"anbernic,[^"]+"/)
        if (RSTART > 0) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
    }' linux/sun50i-h700-anbernic-rg40xx-v.dts)

if [ -z "$panel_compat" ]; then
    fail "no anbernic panel compatible found in the board DTS"
else
    blob="rootfs_overlay/lib/firmware/panels/${panel_compat}.panel"
    [ -f "$blob" ] \
        && ok "panel '$panel_compat' has its blob at $blob" \
        || fail "panel '$panel_compat' has no blob at $blob"
fi

# Both variants ship regardless of which one is selected: the wrong one is
# unusable on the wrong hardware, and a blank screen is a poor way to find
# that out. Switching variants should be a one-line DTS change and nothing
# more.
for v in anbernic,rg40xx-panel anbernic,rg40xx-v2-panel; do
    [ -f "rootfs_overlay/lib/firmware/panels/${v}.panel" ] \
        && ok "variant blob present: ${v}.panel" \
        || fail "variant blob missing: ${v}.panel"
done

# fbcon is the only console this board has. Losing console=tty0 would silently
# take the screen back out of the boot path.
for f in rootfs_overlay/boot/extlinux/extlinux-a.conf rootfs_overlay/boot/extlinux/extlinux-b.conf; do
    grep -q 'console=tty0' "$f" \
        && ok "$(basename "$f") puts the kernel log on the panel" \
        || fail "$(basename "$f") is missing console=tty0"
done

# The panel driver is loaded explicitly by erlinit, because it can neither be
# built in (request_firmware runs before the rootfs is mounted) nor autoload
# (the SPI modalias is derived from the panel's own compatible string, not the
# driver's). Both were established on hardware. If this line is lost the screen
# stops working, and the symptom points somewhere else entirely: every other
# display driver still binds and /sys/class/backlight still appears, but there
# is no /sys/class/drm/card0.
if grep -q '^--pre-run-exec .*modprobe panel-mipi' rootfs_overlay/etc/erlinit.config; then
    ok "erlinit loads the panel driver before starting the BEAM"
else
    fail "erlinit.config does not modprobe panel-mipi -- the screen will stay dark"
fi

# And the module has to exist to be loaded, which means not built in.
if grep -q '^CONFIG_DRM_PANEL_MIPI=m' linux/linux-6.18.defconfig; then
    ok "the panel driver is a module, as the firmware load requires"
else
    fail "CONFIG_DRM_PANEL_MIPI must be =m; built in, request_firmware runs"
    fail "before the rootfs is mounted and the panel never probes"
fi

echo
if [ "$rc" -eq 0 ]; then echo "Image layout is self-consistent"; else echo "CONSISTENCY CHECK FAILED"; fi
exit $rc
