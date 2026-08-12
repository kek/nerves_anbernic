# Spec: the RG40XXV display panel

**Date:** 2026-08-12
**Status:** Reference. Satisfies prerequisite 3 of
`2026-08-12-display-support-plan.md`.
**Source:** ROCKNIX `distribution`, `projects/ROCKNIX/devices/H700`, read from a
local clone. Everything below is from committed source rather than a decompiled
DTB, so it comes with comments and history.

## Architecture: DPI video plus an SPI command channel

Despite the driver being called `panel-mipi-dpi-spi`, this is **not** a MIPI DSI
panel. The pixel data is parallel RGB888 into `tcon_lcd0`, and panel
initialisation is sent over a **bit-banged 3-wire SPI** side channel using
`spi-gpio`. Getting a picture therefore requires both paths to work, and they
fail independently.

## Hardware wiring

From ROCKNIX `0002-rg35xx-enable-HDMI-LCD.patch`, in the parent
`sun50i-h700-anbernic-rg35xx-2024.dts`:

| Function | Pin | Notes |
|---|---|---|
| LCD 3V3 enable (`reg_lcd`) | PI15 | `regulator-fixed`, active high |
| SPI clock | PI9 | `spi-gpio` |
| SPI MOSI | PI10 | `spi-gpio` |
| SPI chip select | PI8 | `spi-gpio`, `num-chipselects = <1>` |
| Panel reset | PI14 | active **low** |
| Pixel data | `lcd0_rgb888_pins` | RGB888 parallel → `tcon_lcd0` |
| Backlight PWM | PD28 | `pwm0`, `pwm-backlight`, 40000 ns period |

SPI is `spi-3wire` at `spi-max-frequency = <3125000>`.

Also needed: `&de { status = "okay" }`, `&tcon_lcd0 { status = "okay" }`,
`&pwm { status = "okay" }`, and `tcon_lcd0_out_lcd` ↔ `panel_in_rgb` endpoints.

## The panel description is a firmware blob, not device tree

This is the part that would be silently missed. The generic driver loads the
panel's timings *and* its init sequence from a file at runtime:

> The name of the file is `panels/<compatible>.panel`, where the `<compatible>`
> is the first string of the `compatible` property defined in the Device Tree.

So the image must ship, in `/lib/firmware/panels/`:

```
anbernic,rg40xx-panel.panel
anbernic,rg40xx-v2-panel.panel
```

They live in ROCKNIX at
`projects/ROCKNIX/packages/linux-firmware/kernel-firmware/extra-firmware/panels/`.

**Kernel patches plus device tree without these files gives no picture and no
obvious error.** There is no `panel-timing` node anywhere; do not go looking for
one.

Blob layout, per the driver's own documentation: a 16-byte header
(`PANEL-FIRMWARE` + format version 1), a 48-byte big-endian config, an array of
32-byte big-endian timings, then the init sequence as length-prefixed MIPI
commands (`0x00` = sleep 10 ms, `0x80` = sleep 100 ms).

## The two variants, decoded

Both files decoded with the structs from the driver patch:

| | `rg40xx-panel` | `rg40xx-v2-panel` |
|---|---|---|
| Physical size | 81 × 61 mm | 81 × 61 mm |
| Preferred mode | **640×480 @ 60.00 Hz**, 27000 kHz | **640×480 @ 60.00 Hz**, 27000 kHz |
| Blanking | h(fp 64, sync 4, bp 42) v(fp 100, sync 4, bp 16) → 750×600 | identical |
| Extra mode | 640×480 @ 120 Hz (54000 kHz) | none |
| Mode flags | `0xa` = NHSYNC \| NVSYNC | `0x5` = PHSYNC \| PVSYNC |
| `bus_flags` | `0x0000000a` | `0x00000046` |
| reset / init delay | 1 ms / 10 ms | 5 ms / 20 ms |
| Init sequence | 537 bytes | 731 bytes |

### The consequence that matters

**The timings are identical, so `modetest` will report 640×480 @ 60 Hz for both
variants.** A plausible-looking mode does *not* confirm the right panel.

What actually differs is the init sequence, the **sync polarity** (inverted
between them) and the pixel-data clock edge in `bus_flags`. That is consistent
with the reported symptom of the wrong variant giving a "blank or scrambled"
screen: wrong sync polarity and a wrong controller init, at the right
resolution.

So a scrambled image means **wrong variant**, not wrong timings — and it is
cheap to test, since selecting a variant is one `compatible` string. Try
`anbernic,rg40xx-panel` first; if the image is scrambled or absent while the
mode reads correctly, switch to `anbernic,rg40xx-v2-panel`. That is a faster
answer than identifying the panel any other way.

## Device tree for our board

The RG40XXV DTS in ROCKNIX adds almost nothing for display — it only overrides
the compatible, because `spi_lcd`, `reg_lcd`, `panel@0`, `de` and `tcon_lcd0`
all come from the patched parent:

```dts
&panel {
	compatible = "anbernic,rg40xx-panel", "panel-mipi-dpi-spi";
};
```

and the v2 variant is the same file with `anbernic,rg40xx-v2-panel`.

## The patches actually needed

ROCKNIX carries 23 kernel patches for H700; only **7 are display**. The README's
"roughly 23 patches" overstates the scope of this work.

| Patch | What it does |
|---|---|
| `0002-rg35xx-enable-HDMI-LCD.patch` | The big one (2369 lines): sun4i DRM (mixer, planes, tcon, hdmi phy), de2 clocks, display nodes in `sun50i-h616.dtsi`, and the panel/`spi_lcd`/`reg_lcd`/`de`/`tcon_lcd0` DT above, plus binding docs |
| `0003-Update-sun8i_tcon_top.c.patch` | TCON top driver |
| `0008-…introduce_allwinner_h616_pwm_controller.patch` | H616 PWM controller — upstream posting v8, 2026-08-04 |
| `0010-rg35xx-enable-pwm-backlight.patch` | `pwm-backlight` node and PD28 pinmux |
| `0110-…drm_panel_add_generic_mipi_panel_driver.patch` | The generic panel driver — upstream posting v2, 2025-02-26 |
| `0111-rg35xx-2024-use-panel-mipi-dpi-spi-driver.patch` | Adds the `panel-mipi-dpi-spi` fallback compatible |
| `0155-sun4i-set-rgb-connector-as-DSI.patch` | sun4i RGB connector treated as DSI |

Two of these are upstream submissions in flight (`0008`, `0110`), so expect to
drop rather than carry them. Note `0002` also touches unrelated boards and
binding documentation — it will need trimming for our tree.

Deliberately **not** wanted: `0140-rg35xx-2024-use-rocknix-joypad-driver.patch`
and friends pull in an out-of-tree joypad driver, and `0127-enable-mmc1-*` is
ROCKNIX's approach to the WiFi problem we already solved differently, with
`patches/linux/0001-mmc-pwrseq_simple-gpio-reset-fallback.patch`.

## Unrelated find worth keeping

`0151-phy-fix-OTG-host-mode.patch` looks like the fix for the USB gadget
limitation in the README. Its rationale:

> For SoCs with dual route the PHY mode is fully determined by the selected mux
> route (i.e. USB controller to use). As both host (EHCI/OHCI) and peripheral
> (MUSB) controllers use the same PHY, both drivers can try to set PHY mode.

That matches the observed symptom exactly — `phy-5100400.phy.0: Changing
dr_mode to 1` (`USB_DR_MODE_HOST`) during boot, after which the gadget binds but
the host never enumerates it. Worth trying independently of display work.
