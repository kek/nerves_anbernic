# Changelog

## v0.1.0

Initial release: headless Nerves support for the Anbernic RG40XXV
(Allwinner H700).

Built on mainline Linux 6.18 with no out-of-tree kernel patches. The board
device tree extends mainline's `sun50i-h700-anbernic-rg35xx-plus.dts`, so
the AXP717 PMIC, battery and USB power supplies, MicroSD, gamepad and volume
buttons, LEDs, audio codec, USB, RTL8821CS WiFi and Bluetooth all come from
upstream.

Boot chain is SPL → ATF BL31 (`sun50i_h616`) → U-Boot 2026.04 → `sysboot`,
with A/B rootfs partitions and revert support.

Known limitation: the 4" LCD and HDMI are not supported, because mainline
has no display support for any H700 board. See the README.

On-device boot is unverified — no hardware was available. The device tree,
kernel configuration, and firmware build are verified; see "How this was
verified" in the README and the hardware checklist alongside it.
