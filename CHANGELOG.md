# Changelog

## Unreleased

**The mini-HDMI port is described.** The device tree now carries
`hdmi@6000000`, `hdmi-phy@6010000`, `lcd-controller@6515000` (TCON TV0) and an
`hdmi-connector`, so the pipeline forks after TCON TOP: `mixer0 -> tcon_top ->
tcon_lcd0 -> panel` as before, and `mixer0 -> tcon_top -> tcon_tv0 -> hdmi`
alongside it. `CONFIG_DRM_SUN8I_DW_HDMI` goes to `=y`.

Only one new kernel patch was needed.
`patches/linux/0105-drm-sun4i-add-the-h616-hdmi-phy-variant.patch` is Jernej
Skrabec's H616 HDMI PHY support — three configuration tables and one
`of_device_id` entry, 75 lines. Everything else was already here or already
upstream: `sun8i_dw_hdmi.c` matches through the `allwinner,sun50i-h6-dw-hdmi`
fallback with the correct quirks, the `allwinner,sun50i-h616-tcon-tv` quirks
(including the `hdmi_pad` bit) came in with `0100` for the panel, and every
clock and reset the new nodes reference is already in 6.18.44's H616 CCU
headers.

> [!WARNING]
> **Never tested on hardware.** No kernel from this tree has ever driven the
> HDMI port. And the risk is not confined to HDMI: `sun4i-drm` is a component
> master, and the HDMI controller, PHY and TCON TV0 are now components of it,
> so one of them failing to bind takes down **the panel as well**. Flash this
> to a slot you can lose and do not `VALIDATE` until the screen comes up.

Two limits are structural rather than provisional:

- **The panel and HDMI cannot be on at the same time.** DE33's plane registers
  are one block shared by both mixers, upstream's mixer binding claims that
  block exclusively as `reg` index 0, and a second mixer node asking for the
  same window fails with `-EBUSY`. So this tree has one mixer, both CRTCs
  resolve to it, and `TCON_TOP_PORT_SEL` feeds one TCON at a time. The
  refactor that lifts this is still in review on dri-devel.
- **Picture only, no HDMI audio.** It runs through Allwinner's audio hub, whose
  driver has never been submitted upstream; ROCKNIX carries one and ships it
  disabled.

`tools/check-dts.sh` asserts the whole HDMI branch, including that each TCON
keeps exactly one input endpoint — two would send
`sun4i_tcon_find_engine()` down an id-matching path that cannot work with a
single mixer, and the symptom would be no display at all.

**The power button reaches Linux, and power off now powers off.** Two separate
absences, either of which alone left the same symptom.

The button is not a GPIO — it goes to the AXP717's PWRON pin, so without
`CONFIG_INPUT_AXP20X_PEK` nothing ever learned it had been pressed.
`/proc/bus/input/devices` listed four devices and no power key. No device tree
change was needed: `axp20x.c` already registers an `axp20x-pek` cell for this
PMIC with both edge interrupts, and the driver binds it by platform device id.
The option was the only thing missing.

And `axp20x_power_off()` writes `AXP20X_OFF_CTRL` (0x32) for every variant
without its own case, a register the AXP717's map does not have at all. The
write was silently dropped, shutdown fell through to PSCI `SYSTEM_OFF`, the ATF
this board boots has no driver for the PMIC either, and the watchdog turned
every power off into a reboot.
`patches/linux/0003-mfd-axp20x-power-off-the-AXP717-via-SOFT_PWROFF.patch` sets
`SOFT_PWROFF` (0x27) bit 0 instead. Verified on the RG40XXV: the board goes
down and stays down. With a charger attached the PMIC boots it again on VBUS
presence, which is what the stock firmware does too and not this patch's doing.
The same default-case write is still in mainline as of 6.19-rc, so this is a
candidate for upstream submission rather than a backport.

> [!IMPORTANT]
> **Input event nodes renumbered.** The power key took `event0`, moving the
> gamepad to `event2`, the volume keys to `event3` and the headphone jack to
> `event4`. Anything opening a hardcoded path is now wrong; look devices up by
> name.

**The analog stick is described, for the first time.** This tree extends
mainline's `rg35xx-plus.dts`, whose board has no stick, so the one control the
two boards do not share was the one that went missing — Linux reported an
RG40XX V with fifteen keys and no `ev_abs` on any device. The stick has no ADC
of its own: it runs through a 4:1 analog multiplexer into the H700's single
GPADC channel, PI1 and PI2 selecting and PI0 enabling, so the chain is
`adc-joystick` over `io-channel-mux` over `gpio-mux` over the GPADC, and
`nerves.fragment` gains the four drivers built in. The click is described too,
as `BTN_THUMBL` on PE8, confirmed by pressing it; PE9's `BTN_THUMBR` is not,
because this shell has no second stick and a `gpio-keys` entry for a switch
that is not fitted chatters.

What is measured and what is not is worth keeping straight: the wiring is
measured, out of muOS's vendor tree for this exact device. Which two of the
four mux positions carry X and Y, and which way round each axis runs, are taken
from the two-stick sibling's left stick. All four positions are declared rather
than two, which puts every one in sysfs so that moving the stick while reading
`in_voltage[0-3]_raw` settles it. See [verifying it on a
device](docs/debugging.md#verifying-it-on-a-device).

**`vdd-dram` is Anbernic's own 1.2 V**, read off the PMIC on a booted muOS card
rather than inferred. The previous 1.1 V was an import from an LPDDR4
defconfig and not a property of this board. The wider question — that this
board is LPDDR3 and not the LPDDR4 its sibling's defconfig declares — is
settled four ways in [DRAM verification](docs/dram-verification.md).

**Nine kernel patches** are now carried in `patches/linux/`, the new ones being
the AXP717 power-off and the H616 HDMI PHY above.

`docs/superpowers/` was deleted, its one remaining document having moved out to
the project journal, and `docs/**` is now globbed as CC-BY-4.0 rather than
named document by document.

## v0.2.0

A minor release under semantic versioning: the boot logo is a new,
backward-compatible feature, and nothing about the board support, the partition
layout or the API surface changed. Confirmed on hardware before the bump —
panel at 2.4 s, and the four-mark strip in place of four Tuxes.

**The boot logo is the four marks this firmware actually runs**: Tux, Erlang,
Elixir and Nerves, side by side on black. The stock kernel drew four Tuxes,
because `CONFIG_LOGO` draws one copy per online CPU. There is no kernel
mechanism for four *different* images, but fbcon fits n copies where
`n*(width+8)-8 <= xres`, so a 588 px strip on a 640-wide panel is drawn exactly
once. Buildroot does the embedding natively through
`BR2_LINUX_KERNEL_CUSTOM_LOGO_PATH`, at the cost of host-imagemagick joining
the build. See [the boot logo](docs/boot-logo.md).

**The path-referenced-content trap in [`docs/hacking.md`](docs/hacking.md) is
generalised**, because that logo option joined the family the same day and was
observed in the wild: the volume's `.config` carried the option,
host-imagemagick was built as its new dependency, and the kernel was repackaged
with the stock Tux still inside it under a fresh checksum — the logo conversion
is a pre-build hook of a `linux` package already stamped `.stamp_built`, and
Buildroot does not rebuild on config changes. The documented recipe is now
stamp deletion rather than `make linux-rebuild`, which is equivalent but keeps
the Nerves environment handling, and there is a verification command per trap.
CI never hits any of this; fresh builds have no stamps. It is purely a hazard
of the fast local loop, which is exactly when nobody is in the mood to check
what actually shipped.

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
than left to mislead. CI enforces the rule by asserting that a tag matches
`VERSION`.
