#!/bin/bash
#
# Container-side half of tools/gen-kernel-defconfig.sh. Not meant to be run
# directly on a host -- it installs packages and downloads a kernel.
#
# Expects: KVER, KMAJOR, SERIES, OUT in the environment, /repo mounted.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    bc bison flex gcc make libssl-dev libelf-dev curl ca-certificates \
    xz-utils python3 >/dev/null

echo "==> Downloading linux-${KVER}"
cd /build
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KVER}.tar.xz" | tar -xJ
cd "linux-${KVER}"

echo "==> make ARCH=arm64 defconfig"
make ARCH=arm64 defconfig >/dev/null

echo "==> merging nerves.fragment"
./scripts/kconfig/merge_config.sh -m -O . .config /repo/linux/nerves.fragment

echo "==> make ARCH=arm64 olddefconfig"
make ARCH=arm64 olddefconfig >/dev/null

rc=0

echo "==> verifying every symbol the fragment asked for actually took"
while IFS= read -r line; do
    case "$line" in
        "# CONFIG_"*" is not set")
            sym=${line#\# }; sym=${sym%% is not set}
            if grep -q "^${sym}=" .config; then
                echo "  MISMATCH: $sym should be unset but is set"; rc=1
            fi
            ;;
        CONFIG_*=*)
            sym=${line%%=*}; want=${line#*=}
            got=$(grep "^${sym}=" .config | head -1 | cut -d= -f2- || true)
            if [ -z "$got" ]; then
                echo "  MISSING: $sym (wanted $want) -- not in final config"; rc=1
            elif [ "$got" != "$want" ]; then
                echo "  DOWNGRADED: $sym wanted $want got $got"; rc=1
            fi
            ;;
    esac
done < <(grep -E "^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)" /repo/linux/nerves.fragment)

echo
echo "==> boot-critical driver checklist (from the full .config)"
# Anything here being absent means the board does not come up, or comes up
# missing hardware the README claims works. Checked against .config rather
# than the savedefconfig, because savedefconfig omits symbols that already
# match their Kconfig default.
required="
  ARCH_SUNXI PINCTRL_SUN50I_H616 PINCTRL_SUN50I_H616_R SUN50I_H616_CCU
  SUNXI_CCU MMC MMC_SUNXI SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_8250_DW
  SQUASHFS SQUASHFS_XZ SQUASHFS_ZSTD F2FS_FS DEVTMPFS DEVTMPFS_MOUNT
  I2C I2C_MV64XXX MFD_AXP20X_I2C REGULATOR_AXP20X AXP20X_ADC
  AXP20X_POWER BATTERY_AXP20X
  INPUT_EVDEV KEYBOARD_GPIO NEW_LEDS LEDS_CLASS LEDS_GPIO
  CFG80211 RTW88 RTW88_8821CS
  NVMEM_SUNXI_SID RTC_DRV_SUN6I PHY_SUN4I_USB
  USB_MUSB_HDRC USB_MUSB_SUNXI USB_GADGET USB_CONFIGFS
  USB_CONFIGFS_ECM USB_CONFIGFS_ACM SND_SUN4I_CODEC
"
# Present but not fatal. The README describes these as working, so a
# regression should be visible, but they do not stop a boot.
optional="
  SND_SUN8I_CODEC_ANALOG DRM_PANFROST BT BT_HCIUART
  BT_HCIUART_RTL SUN8I_THERMAL SUNXI_WATCHDOG ZRAM
"
for sym in $required; do
    got=$(grep "^CONFIG_${sym}=" .config | head -1 | cut -d= -f2- || true)
    if [ -z "$got" ]; then
        echo "  REQUIRED MISSING: CONFIG_${sym}"; rc=1
    else
        echo "  ok       CONFIG_${sym}=${got}"
    fi
done
for sym in $optional; do
    got=$(grep "^CONFIG_${sym}=" .config | head -1 | cut -d= -f2- || true)
    if [ -z "$got" ]; then
        echo "  ABSENT   CONFIG_${sym} (optional)"
    else
        echo "  ok       CONFIG_${sym}=${got}"
    fi
done

# An initramfs would mean erlinit is not PID 1 straight out of the squashfs.
if grep -q "^CONFIG_BLK_DEV_INITRD=y" .config; then
    echo "  UNEXPECTED: CONFIG_BLK_DEV_INITRD=y"; rc=1
else
    echo "  ok       CONFIG_BLK_DEV_INITRD unset"
fi

echo
echo "==> make ARCH=arm64 savedefconfig"
make ARCH=arm64 savedefconfig >/dev/null
cp defconfig "/repo/${OUT}"
wc -l "/repo/${OUT}"

exit $rc
