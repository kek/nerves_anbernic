# Changelog

## v0.1.0

Initial release: headless Nerves support for the Anbernic RG40XXV
(Allwinner H700).

Built on Linux 6.18. The board device tree extends mainline's
`sun50i-h700-anbernic-rg35xx-plus.dts`, so the AXP717 PMIC, battery and USB
power supplies, MicroSD, gamepad and volume buttons, LEDs, audio codec, USB,
RTL8821CS WiFi and Bluetooth all come from upstream.

Six kernel patches are carried, in `patches/linux/`: two found during bring-up
(an SDIO reset fallback that WiFi needs, and a USB phy mode fix that the USB
gadget needs), and four for the display.

Boot chain is SPL → ATF BL31 (`sun50i_h616`) → U-Boot 2026.04 → `sysboot`,
with A/B rootfs partitions and revert support.

The device boots, joins WiFi, and answers SSH over both WiFi and the USB-C
cable. Five separate bugs had to be fixed to get there;
[`docs/bring-up.md`](docs/bring-up.md) records them.

The 4" LCD is described end to end — patches, device tree and panel firmware —
but is **not yet confirmed to light up**. HDMI is not described at all. See
[`docs/display.md`](docs/display.md) for what is verified and what is not, and
for how to read the result.
