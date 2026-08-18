# Changelog

## v0.1.0

First release of Nerves support for the Anbernic RG40XXV (Allwinner H700),
confirmed working on hardware.

Built on Linux 6.18.44 with the Nerves aarch64 toolchain. The board device tree
extends mainline's `sun50i-h700-anbernic-rg35xx-plus.dts`, so the AXP717 PMIC,
battery and USB power supplies, MicroSD, gamepad and volume buttons, LEDs, audio
codec, USB, RTL8821CS WiFi and Bluetooth all come from upstream.

Boot chain is SPL → ATF BL31 (`sun50i_h616`) → U-Boot 2026.04 → `sysboot`, with
A/B rootfs partitions and revert support.

**On a device:** boots, joins WiFi on 5 GHz, answers SSH over both WiFi and the
USB-C cable, drives the 4" 640×480 panel, and runs GLES2 on the Mali-G31 through
Panfrost and Mesa. Both SD slots, with ext4, vfat, exFAT and f2fs.

**The display comes up at 2.4 seconds.** The whole sun4i stack is built into the
kernel and the panel description is linked in with `CONFIG_EXTRA_FIRMWARE`, so
nothing waits for a filesystem. Getting there took two separate discoveries: one
missing device tree property — `reg = <0>` on TCON TOP's output endpoint, which
is a TCON index rather than a port number — that routed the mixer to the wrong
TCON and produced a uniform colour with no error anywhere; and a modular
`gpio-backlight` that held the built-in panel in deferred probe for seven silent
seconds. [`docs/display.md`](docs/display.md) has both in full.

Seven kernel patches in `patches/linux/`: two found during bring-up — an SDIO
reset fallback without which there is no WiFi, and a USB phy mode fix without
which the gadget never enumerates — and five for the H616 display stack. Two
Buildroot patches in `patches/buildroot/`. None are upstream as of 6.18, so all
need re-checking on a kernel bump.

Five hardware surprises had to be found the hard way, none of them visible from
source review; [`docs/bring-up.md`](docs/bring-up.md) records them, starting with
the board being LPDDR3 rather than the LPDDR4 its sibling's defconfig declares.

**Known limitations:** no HDMI, no software power-off, and `nerves_ssh` cannot
generate host keys on OTP 29 — ship them in your application's `rootfs_overlay`.

### A note on the numbering

This is the first release under a scheme where `VERSION`, the git tag and the
release all say the same thing, asserted in CI. Seven earlier tags exist in this
project's history that did not: `VERSION` stayed at `0.1.0` while the tags ran to
`v0.7.0`, and because `mix deps.get` resolves against `v$VERSION` rather than
against the tag, three of them published perfectly good artifacts onto release
pages nothing would ever read. Those tags and releases have been deleted rather
than left to mislead. See
[`docs/superpowers/specs/2026-08-18-release-scheme.md`](docs/superpowers/specs/2026-08-18-release-scheme.md).
