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
# Two warnings are expected. unit_address_vs_reg on /soc comes from mainline's
# sun50i-h616.dtsi, not from us. graph_child_address on tcon-top's port@1 is
# ours and is deliberate: see the note in the DTS: the cells look unnecessary
# to dtc because the port has one child, but dropping them makes dtc inherit
# <2>/<1> from /soc and emit six warnings instead of one.
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

# The second card slot. mmc@4022000 is disabled in sun50i-h616.dtsi and no
# mainline board in this family enables it, so this is entirely ours and there
# is no upstream to notice if it regresses. Assert against the decompiled DTB
# rather than the source: the whole point is that status actually reached the
# node we think it did.
mmc2_status=$(fdtget /tmp/board.dtb /soc/mmc@4022000 status 2>/dev/null || echo MISSING)
if [ "$mmc2_status" = "okay" ]; then
    echo "  ok       second card slot mmc@4022000 is enabled"
else
    echo "  FAILED   mmc@4022000 status is '$mmc2_status', wanted okay."
    echo "           That node is the games card slot; disabled means the"
    echo "           card never appears as a block device at all."
    rc=1
fi
# Card detect and the slot's 3V3 switch. Both are on bank PE and both were
# cross-checked against Anbernic's vendor DTB -- see the comment on &mmc2 in
# the DTS. A wrong cd-gpios is the nasty one: the slot probes cleanly and
# simply never notices a card.
mmc2_cd=$(fdtget -t x /tmp/board.dtb /soc/mmc@4022000 cd-gpios 2>/dev/null || echo MISSING)
case "$mmc2_cd" in
    *" 4 16 1"|*" 0x4 0x16 0x1") echo "  ok       mmc2 card detect is PE22, active low" ;;
    *) echo "  FAILED   mmc2 cd-gpios reads '$mmc2_cd', wanted bank 4 pin 0x16 flag 1 (PE22, active low)"
       rc=1 ;;
esac
assert_match "mmc2 3V3 load switch present" 'regulator-name = "vcc3v3-mmc2"'
# 4-bit, and 3V3-only. The vendor DTB sets sunxi-dis-signal-vol-sw; dropping
# no-1-8-v would let the core try a UHS voltage switch the slot cannot do.
mmc2_bw=$(fdtget /tmp/board.dtb /soc/mmc@4022000 bus-width 2>/dev/null || echo MISSING)
if [ "$mmc2_bw" = "4" ]; then
    echo "  ok       mmc2 bus-width is 4"
else
    echo "  FAILED   mmc2 bus-width is '$mmc2_bw', wanted 4"
    rc=1
fi
if fdtget /tmp/board.dtb /soc/mmc@4022000 no-1-8-v >/dev/null 2>&1; then
    echo "  ok       mmc2 is pinned to 3V3 signalling (no-1-8-v)"
else
    echo "  FAILED   mmc2 has no no-1-8-v; the slot has no 1V8 rail"
    rc=1
fi

# The boot slot must stay untouched by all of the above. root=/dev/mmcblk0p2
# is on the kernel command line, so a change here is an unbootable image.
mmc0_cd=$(fdtget -t x /tmp/board.dtb /soc/mmc@4020000 cd-gpios 2>/dev/null || echo MISSING)
case "$mmc0_cd" in
    *" 5 6 1"|*" 0x5 0x6 0x1") echo "  ok       boot slot mmc@4020000 card detect is still PF6" ;;
    *) echo "  FAILED   mmc0 cd-gpios reads '$mmc0_cd', wanted bank 5 pin 6 flag 1 (PF6)"
       rc=1 ;;
esac

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

# Display pipeline. This board is no longer headless; what used to be a
# trip-wire against any panel node is now a check that the whole chain is
# present, because a partial pipeline is the failure mode that looks like a
# hardware problem. Every link below is one that produces "no picture, no
# error" when it is missing.
assert_match "display-engine present" 'allwinner,sun50i-h616-display-engine'
assert_match "DE33 bus present" 'allwinner,sun50i-h616-de33'
assert_match "DE33 clocks present" 'allwinner,sun50i-h616-de33-clk'
assert_match "mixer0 present" 'allwinner,sun50i-h616-de33-mixer-0'
assert_match "TCON TOP present" 'allwinner,sun50i-h616-tcon-top'
assert_match "TCON LCD0 present" 'allwinner,sun50i-h616-tcon-lcd'

# Which TCON the display engine is routed to comes from the reg of the
# endpoint in TCON TOP's *output* port, and it is a TCON index rather than a
# port number. sun4i_tcon_of_get_id_from_port() reads it with
# of_property_read_u32() and has no default, so omitting it returns -EINVAL --
# and nothing checks the sign. sun8i_tcon_top_de_config() only rejects
# tcon > 3, so -22 reaches FIELD_PREP(TCON_TOP_PORT_DE0_MSK, ...) whose
# two-bit mask yields 2. TCON_TOP_PORT_SEL then routes mixer0 to TCON2 while
# the panel hangs off TCON0: the panel shows a constant colour, the display
# engine never completes a frame, and every register anyone thinks to compare
# looks correct. That is exactly how this was found -- PORT_SEL read 0x22
# against a working muOS's 0x20.
tcon_ep_reg=$(fdtget /tmp/board.dtb \
    /soc/tcon-top@6510000/ports/port@1/endpoint@0 reg 2>/dev/null || echo MISSING)
if [ "$tcon_ep_reg" = "0" ]; then
    echo "  ok       TCON TOP output endpoint is reg = <0>, routing mixer0 to TCON0"
else
    echo "  FAILED   TCON TOP output endpoint reg is '$tcon_ep_reg', wanted 0."
    echo "           That value is the TCON index. Wrong or missing, the DE is"
    echo "           routed to a TCON the panel is not on, and the screen shows"
    echo "           a constant colour with no error anywhere."
    rc=1
fi
# Variant-agnostic on purpose. Either blob is a legitimate choice and switching
# between them is a one-line DTS change, so pinning the spelling here just means
# a red CI run every time someone tries the other panel. That the *selected*
# variant has a matching blob is asserted by tools/check-consistency.sh, which
# is the property that actually matters.
assert_match "panel present" 'anbernic,rg40xx(-v2)?-panel'
assert_match "panel falls back to the generic driver" 'panel-mipi-dpi-spi'
assert_match "panel command channel is bit-banged SPI" 'spi-gpio'
assert_match "backlight present" 'gpio-backlight'

# 6.18.44 implements DE33 planes inside the mixer and wants three named
# register windows. ROCKNIX carries a newer refactor that splits the layer
# registers into a separate planes@ node instead; taking its device tree
# without its drivers gives a mixer that probes and a screen that never
# lights. So pin the binding we actually build against.
assert_match "mixer uses upstream's three-window binding" \
    'reg-names = "layers", "top", "display"'
if grep -qE 'de33-planes' /tmp/board.decompiled.dts; then
    echo "  FAILED   a de33-planes node is present. That belongs to ROCKNIX's"
    echo "           separate planes driver, which this tree deliberately does"
    echo "           not carry -- see patches/linux/0100's header."
    rc=1
else
    echo "  ok       no de33-planes node (upstream mixer owns the planes)"
fi

# The parallel RGB pinmux. Without it the TCON drives nothing, and bank D has
# no supply by default because nothing used it before the display.
assert_match "RGB888 pinmux present" 'function = "lcd0"'

echo
if [ "$rc" -eq 0 ]; then
    echo "DTS OK ($(stat -c %s /tmp/board.dtb) bytes)"
else
    echo "DTS CHECK FAILED"
fi
exit $rc
