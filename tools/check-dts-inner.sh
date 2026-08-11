#!/bin/bash
#
# Container-side half of tools/check-dts.sh. Expects KVER/KMAJOR in the
# environment and /repo mounted.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    device-tree-compiler gcc curl ca-certificates xz-utils >/dev/null

DTS_NAME=sun50i-h700-anbernic-rg40xx-v

echo "==> Fetching the parts of linux-${KVER} that dtc needs"
cd /build
# Only the device trees and the headers they include. include/uapi/linux is
# needed because dt-bindings/input/linux-event-codes.h is a symlink into it.
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KVER}.tar.xz" \
  | tar -xJ \
      "linux-${KVER}/arch/arm64/boot/dts" \
      "linux-${KVER}/include/dt-bindings" \
      "linux-${KVER}/include/uapi/linux" \
      "linux-${KVER}/scripts/dtc/include-prefixes"
cd "linux-${KVER}"

# Buildroot's BR2_LINUX_KERNEL_CUSTOM_DTS_PATH copies the DTS into
# arch/<arch>/boot/dts (flat), which is why the board DTS includes its parent
# with an "allwinner/" prefix. Reproduce that placement exactly.
cp "/repo/linux/${DTS_NAME}.dts" arch/arm64/boot/dts/

echo "==> cpp"
cpp -nostdinc -I scripts/dtc/include-prefixes -undef -D__DTS__ \
    -x assembler-with-cpp -o /tmp/board.dts.tmp \
    "arch/arm64/boot/dts/${DTS_NAME}.dts"

echo "==> dtc"
# The unit_address_vs_reg warning on /soc comes from mainline's
# sun50i-h616.dtsi, not from us.
dtc -I dts -O dtb -i arch/arm64/boot/dts -i arch/arm64/boot/dts/allwinner \
    -o /tmp/board.dtb /tmp/board.dts.tmp

echo "==> decompiling for assertions"
dtc -I dtb -O dts /tmp/board.dtb > /tmp/board.decompiled.dts 2>/dev/null

rc=0
assert_match() {
    local what="$1" pattern="$2"
    if grep -qE "$pattern" /tmp/board.decompiled.dts; then
        echo "  ok       $what"
    else
        echo "  FAILED   $what (no match for: $pattern)"
        rc=1
    fi
}

# Identity. If the model is wrong, the wrong DTB got built or the wrong
# parent was included.
assert_match "model is Anbernic RG40XX V" 'model = "Anbernic RG40XX V"'
assert_match "compatible names rg40xx-v and sun50i-h700" \
    'compatible = "anbernic,rg40xx-v", "allwinner,sun50i-h700"'

# Our one actual addition. Referenced by path (&{/leds}) because mainline's
# gpio-leds node has no label, so a rename upstream would silently drop it.
assert_match "led-rgb present" 'led-rgb'
assert_match "inherited power LED still present" 'function = "power"'

# Inherited from rg35xx-plus.dts. Without mmc1 there is no WiFi, and this is
# exactly the failure that U-Boot's own DTB would cause.
assert_match "RTL8821CS SDIO WiFi node inherited" 'wifi@1'
assert_match "Bluetooth node inherited" 'realtek,rtl8821cs-bt'

# Inherited from rg35xx-2024.dts.
assert_match "AXP717 PMIC present" 'x-powers,axp717'
assert_match "battery power supply present" 'axp717-battery-power-supply'
assert_match "gamepad buttons present" 'gpio-keys-gamepad'
assert_match "audio codec enabled" 'codec@5096000'

# Button count. Mainline describes 15 gamepad buttons; a silent drop here
# would be hard to spot on device without testing every button.
# Note the hyphen in the character class: the volume keys are button-vol-up
# and button-vol-down.
buttons=$(grep -cE '^[[:space:]]+button-[a-z0-9-]+ \{' /tmp/board.decompiled.dts || true)
if [ "$buttons" -ge 17 ]; then
    echo "  ok       $buttons button nodes (15 gamepad + 2 volume)"
else
    echo "  FAILED   expected at least 17 button nodes, found $buttons"
    rc=1
fi

# Headless by design: no panel should have crept in, since no mainline driver
# exists for it. If this fires, someone added a node without the driver.
if grep -qE 'panel' /tmp/board.decompiled.dts; then
    echo "  FAILED   a panel node is present, but this system is headless"
    rc=1
else
    echo "  ok       no panel node (headless by design)"
fi

echo
if [ "$rc" -eq 0 ]; then
    echo "DTS OK ($(stat -c %s /tmp/board.dtb) bytes)"
else
    echo "DTS CHECK FAILED"
fi
exit $rc
