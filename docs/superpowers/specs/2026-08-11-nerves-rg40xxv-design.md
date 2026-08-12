# Nerves support for the Anbernic RG40XXV

**Date:** 2026-08-11
**Status:** Implemented and confirmed on hardware

> [!NOTE]
> **Corrected after bring-up.** This spec asserted LPDDR4 DRAM and treated
> upstream's H700 U-Boot defconfig as usable as-is. Both were wrong, and it
> was the one place the "package variant of the H616, sibling of the RG35XX"
> premise broke. The RAM row and the U-Boot paragraph below are corrected in
> place; the reasoning that led there is left intact because it was sound
> given what was known. See "What bring-up actually found" in the README.

## Goal

Ship `nerves_system_rg40xxv`, a Buildroot-based Nerves system that boots
Erlang/OTP on the Anbernic RG40XXV handheld, so that
`MIX_TARGET=rg40xxv mix firmware` produces a flashable `.fw`.

Scope for this version is **headless**: everything the mainline kernel
supports, and nothing that requires carrying out-of-tree drivers. The 4"
LCD is explicitly out of scope; see "Display" below for why, and
"Follow-on work" for how it lands later without rework.

## Hardware

| | |
|---|---|
| SoC | Allwinner H700 (quad Cortex-A53, Mali-G31 MP2) |
| RAM | 1 GB **LPDDR3** @ 672 MHz (this spec originally said LPDDR4) |
| Storage | MicroSD |
| PMIC | X-Powers AXP717 |
| Display | 4" 640x480, RGB/DPI-SPI panel |
| WiFi/BT | Realtek RTL8821CS (SDIO + UART) |

The H700 is a **package variant of the H616** that exposes the RGB LCD
pins. This is the single most important fact about this port: mainline
sunxi H616 support applies almost unchanged, in both U-Boot and Linux.

## Upstream status

Verified against upstream trees rather than recalled, because the answer
drives the whole scope decision.

**In mainline Linux** — `arch/arm64/boot/dts/allwinner/` carries
`sun50i-h700-anbernic-rg35xx-{2024,plus,h,sp}.dts`. The 2024 base DTS
provides the AXP717 PMIC with its full regulator tree, battery and USB
power supplies (i.e. a real fuel gauge), `mmc0`, all fifteen gamepad
buttons plus volume keys as `gpio-keys`, LEDs, the audio codec with
headphone detect and speaker-amp GPIO, EHCI/OHCI, `usbotg` in
`peripheral` mode, and an enabled Mali GPU node. `rg35xx-plus.dts` adds
the RTL8821CS SDIO WiFi on `mmc1` and Bluetooth on `uart1`. The WiFi
driver is in-tree: `drivers/net/wireless/realtek/rtw88/rtw8821cs.c`.

**Not in mainline** — there is no RG40XXV board file, and there is no
display support for *any* H700 board. `drivers/gpu/drm/panel` has no
`panel-mipi-dpi-spi`, and no mainline H700 board DTS references a panel,
tcon, or DE2 node. ROCKNIX carries 23 kernel patches for H700 to get a
picture, including an in-flight generic MIPI/DPI-SPI panel driver, an
H616 PWM controller driver, and a sun4i "RGB connector as DSI" hack.

**Downstream** — ROCKNIX, Batocera, and REG-Linux all ship an
`sun50i-h700-anbernic-rg40xx-v.dts`. It is pleasingly thin: an
`#include` of mainline's `rg35xx-plus.dts` plus model/compatible, a
`rocknix-joypad` analog-mux tweak, `uart5`, an RGB LED on PI7, and a
panel compatible string.

**U-Boot** — `configs/anbernic_rg35xx_h700_defconfig` is upstream and was
assumed here to be generic across the H700 Anbernics: LPDDR4 DRAM timings at
672 MHz, AXP717 over R_I2C, SPL status LED. Requires ATF BL31 for
`sun50i_h616`.

The AXP717 and SPL LED parts are indeed reusable. **The DRAM timings are
not** — that defconfig is for the RG35XX, whose memory differs. Applying its
LPDDR4 configuration to the RG40XXV hangs the SPL during DRAM init with no
outward sign whatsoever. The RG40XXV needs
`CONFIG_SUNXI_DRAM_H616_LPDDR3`; the working values were extracted from the
vendor boot0 of a muOS card. There is no RG40XXV defconfig upstream to
import. See `uboot/uboot.defconfig`.

## Design

### Device tree

Ship one board DTS as a kernel patch, derived from the downstream one
but with every out-of-tree dependency removed:

```dts
#include "sun50i-h700-anbernic-rg35xx-plus.dts"

/ {
	model = "Anbernic RG40XX V";
	compatible = "anbernic,rg40xx-v", "allwinner,sun50i-h700";
};

&{/leds} {
	led-rgb { ... PI7 ... };
};

&uart5 { ... };
```

Two deliberate choices:

- **No `rocknix-joypad` node.** Mainline's inherited `gpio-keys` nodes
  give every button as a standard evdev device with no out-of-tree
  driver. The RG40XXV has no analog sticks, so the analog mux the
  downstream DTS configures buys us nothing.
- **`&{/leds}` path reference, not `&leds`.** Mainline's `leds` node
  carries no label; downstream adds one in a separate patch. Referencing
  by path keeps our patch to a single new file and avoids touching a
  mainline DTS, which is what makes this trivially rebasable.

The RG40XXV is the same PCB family as the RG35XX Plus, so the inherited
button GPIO mapping is expected to be correct, but it is inherited
rather than independently confirmed — flagged in the README as the first
thing to check on device.

### Boot chain

```
SPL  →  ATF BL31 (sun50i_h616)  →  U-Boot 2026.04  →  sysboot  →  Linux
```

U-Boot is built with the upstream H700 PMIC values, RG40XXV-specific
LPDDR3 DRAM values (see the note above), and a Nerves
environment that implements A/B selection and revert-on-unvalidated. It
boots via `sysboot`, reading `/boot/extlinux/extlinux-{a,b}.conf` out of
the squashfs rootfs — no FAT boot partition.

**The DTB must be loaded explicitly.** U-Boot's own built-in device tree
is `sun50i-h700-anbernic-rg35xx-2024`, which does not enable `mmc1`, so
booting on U-Boot's DTB would silently produce a board with no WiFi and
the wrong model string. `extlinux.conf` therefore carries an `fdt`
directive pointing at our DTB in `/boot`.

### Image layout

MBR. fwup partition slots are 0-based while Linux device names are
1-based, so slot 1 is `mmcblk0p2`:

```
+------------------------------+
| MBR                          |
| SPL + U-Boot   (offset 8 KiB)|
| U-Boot environment           |
| p2: Rootfs A (squashfs)      |
| p3: Rootfs B (squashfs)      |
| p4: Application (f2fs)       |
+------------------------------+
```

Rootfs partitions are sized larger than the mangopi template's 140 MiB
because an arm64-defconfig-derived kernel plus modules is bigger than a
minimal riscv one.

### Access paths

A handheld has no pin header, so getting a prompt matters more here than
on a dev board.

1. **USB gadget (primary).** Mainline sets `usbotg` to `peripheral`, so
   the USB-C port can present CDC-ECM plus ACM. That gives ssh over
   `usb0` and IEx on `ttyGS0` with nothing but the charging cable.
2. **UART0 on PH pins (fallback).** Internal test pads; the classic
   bring-up path and what the kernel's `stdout-path` points at.
3. **WiFi.** `rtw88_8821cs` with `rtw88/rtw*.bin` firmware from
   `linux-firmware`; `wpa_supplicant` in the image.

`erlinit` is configured for `ttyS0` with `--warn-unused-tty` so a user on
the wrong console gets told so rather than seeing a dead terminal.

### Kernel configuration

Generated rather than hand-written, because hand-authoring a ~5000-line
arm64 defconfig blind is how you get a board that doesn't boot:

1. `make ARCH=arm64 defconfig` — the standard arm64 defconfig already
   covers sunxi, AXP, rtw88, panfrost, and the sun4i codec.
2. Merge `linux/nerves.fragment`, which holds the Nerves-required
   deltas (squashfs, f2fs, no initramfs, USB gadget/configfs, sunxi SID
   nvmem) and switches off other SoC vendors' `ARCH_*` symbols to claw
   back size.
3. `make savedefconfig` → checked in as `linux/linux-6.18.defconfig`.

`tools/gen-kernel-defconfig.sh` reproduces this, so a kernel bump is a
rerun rather than an archaeology exercise. The fragment is the reviewable
artifact; the defconfig is its output.

### Board ID

`boardid` reads the sunxi SID eFuse at
`/sys/bus/nvmem/devices/sunxi-sid0/nvmem`, giving a stable
`nerves-xxxxxxxx` hostname.

## What works, and what doesn't

**Expected working:** boot to IEx, USB gadget networking and console,
WiFi, Bluetooth, all buttons and volume keys as evdev, LEDs, battery
charge/voltage/current via AXP717, audio out with headphone detect, SD,
A/B firmware update with revert.

**Known not working:** the 4" LCD and HDMI — no mainline driver. The GPU
node is enabled and panfrost loads, but there is no display to put it
on.

## Verification

On-device boot cannot be verified from this workstation, so the plan
leans on build-time evidence plus a documented hardware checklist:

- The DTS compiles against the real 6.18 kernel tree with `dtc` —
  catching the `&{/leds}` reference and any include drift.
- A full Buildroot build in Docker produces an actual `.fw`, which
  exercises the defconfig, the ATF/U-Boot wiring, and fwup.conf.
- `nerves_system_linter` for package hygiene.
- README carries a flash-and-boot checklist, buttons first.

## Follow-on work

Display is additive by construction and needs no rework here: a
`linux/display/` patch series (H616 PWM, `panel-mipi-dpi-spi`, sun4i RGB
connector) plus a `-v2-panel` DTS variant for the second panel
revision the device shipped with. It is deliberately deferred because it
pins the system to a downstream stack that must be rebased on every
kernel bump, which is a real ongoing cost to take on knowingly rather
than by accident.
