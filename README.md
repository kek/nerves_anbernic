# Nerves System: Anbernic RG40XXV

[![Hex version](https://img.shields.io/hexpm/v/nerves_system_rg40xxv.svg "Hex version")](https://hex.pm/packages/nerves_system_rg40xxv)

This is the base Nerves System configuration for the [Anbernic
RG40XXV](https://anbernic.com/products/rg-40xxv) handheld — a 4", vertical,
Allwinner H700 device.

| Feature              | Description                                     |
| -------------------- | ----------------------------------------------- |
| CPU                  | Allwinner H700, quad Cortex-A53 @ 1.5 GHz       |
| Memory               | 1 GB LPDDR4                                     |
| Storage              | MicroSD                                         |
| Linux kernel         | 6.18.x mainline                                 |
| IEx terminal         | `ttyS0` (UART0), or USB gadget serial           |
| GPIO, I2C, SPI       | Yes, via [circuits](https://github.com/elixir-circuits) |
| WiFi                 | RTL8821CS, mainline `rtw88_8821cs`              |
| Bluetooth            | RTL8821CS, `btrtl` + H5/3-wire                  |
| Gamepad              | All buttons + volume keys as evdev              |
| Battery / charger    | AXP717, via `/sys/class/power_supply`           |
| Audio                | Speakers + headphone jack with detect           |
| **Display**          | **Not supported — see below**                   |

## The display does not work, on purpose

The 4" LCD is **not supported by this system**, and neither is HDMI.

This is a limitation of upstream Linux rather than a bug here. As of 6.18
there is no display support for *any* Allwinner H700 board: there is no
`panel-mipi-dpi-spi` driver in `drivers/gpu/drm/panel`, and no mainline H700
board device tree describes a panel, TCON, or DE2 node. Getting a picture
requires the out-of-tree stack that ROCKNIX carries — an in-flight generic
MIPI/DPI-SPI panel driver, an H616 PWM driver for the backlight, and a sun4i
"RGB connector as DSI" change — roughly 23 kernel patches.

Carrying that stack means rebasing it on every kernel bump, which is a real
ongoing cost. This system deliberately does not take it on yet, so that
everything it *does* claim rests on plain mainline. See
`docs/superpowers/specs/2026-08-11-nerves-rg40xxv-design.md` for the full
reasoning, and "Adding display support" below for how it would land.

The GPU is not disabled — `panfrost` builds and the Mali node is enabled —
there is simply no display to put it on.

## Getting started

Install the Nerves tooling per the [Nerves installation
guide](https://hexdocs.pm/nerves/installation.html), then:

```bash
mix nerves.new my_app
cd my_app
```

Add this system to `mix.exs`:

```elixir
{:nerves_system_rg40xxv, "~> 0.1", runtime: false, targets: :rg40xxv}
```

Then:

```bash
export MIX_TARGET=rg40xxv
mix deps.get
mix firmware
mix burn
```

## Flashing

> [!WARNING]
> The RG40XXV boots entirely from MicroSD — there is no internal eMMC to
> fall back on. Writing this firmware to the card **destroys the stock
> Anbernic OS on it**. Use a spare card, or image your original card first
> (`dd if=/dev/rdiskN of=stock-backup.img bs=4m`). Keeping the stock card
> intact also gives you a known-good way to confirm the hardware still
> works.

Write to the **OS slot** — the slot the device boots from, `mmc0` in the
device tree. Then insert and power on.

`mix burn` handles this. To write a card by hand:

```bash
fwup _build/rg40xxv_dev/nerves/images/my_app.fw -d /dev/rdiskN
```

## Getting a console

The RG40XXV has no pin header, so plan how you will talk to it before you
flash.

### USB gadget (recommended)

Mainline sets the H700's `usbotg` node to `dr_mode = "peripheral"`, so the
USB-C port can present a network interface and a serial console over the
charging cable. The kernel here is built with `USB_CONFIGFS`, `..._ECM`,
`..._RNDIS`, and `..._ACM`, but nothing composes a gadget at boot — that is
the application's job, as on other Nerves gadget targets.

The simplest route is [`vintage_net_direct`](https://hexdocs.pm/vintage_net_direct):

```elixir
config :vintage_net,
  config: [
    {"usb0", %{type: VintageNetDirect}}
  ]
```

with `nerves_pack` in your deps. You then get `ssh` to the device over the
USB cable.

### UART0

`ttyS0` is UART0 on the PH pins, which is where the kernel's
`stdout-path` points and where `erlinit` puts IEx by default. On these
handhelds it is on internal test pads, so it means opening the case and
soldering. It is the right tool for diagnosing a board that does not boot
far enough to bring up USB.

Settings are 115200 8N1.

### WiFi

`wpa_supplicant`, `wireless-regdb`, and the `rtw88` firmware are all in the
image. Configure it from your application the usual way with
`vintage_net_wifi`.

## Hardware verification checklist

Nothing here has been confirmed on a physical RG40XXV — the system is built
and verified at build time only (see "How this was verified"). When you
flash your first card, these are the things worth checking, roughly in the
order they would tell you something has gone wrong:

1. **It boots at all.** Console output on `ttyS0`. If the SPL never starts,
   suspect the DRAM timings in `uboot/uboot.defconfig`, which come from
   upstream's generic H700 config.
2. **The right device tree loaded.** `cat /proc/device-tree/model` should
   read `Anbernic RG40XX V`. If it says `RG35XX 2024`, U-Boot booted with
   its own built-in DTB instead of ours and WiFi will be missing.
3. **Buttons.** This is the least-certain part. The button GPIO mapping is
   inherited from mainline's `rg35xx-plus.dts` on the grounds that the
   RG40XXV is the same PCB family; that is a reasonable inference, not a
   confirmed fact. Check with `evtest` that every button reports, and that
   the labels match the physical layout.
4. **WiFi.** `ip link` should show a `wlan0`.
5. **Battery.** `/sys/class/power_supply/axp717-battery/` should report a
   plausible voltage and capacity.
6. **Audio**, then **the RGB LED** on PI7.

If buttons are wrong, fixing them is a small edit to
`linux/sun50i-h700-anbernic-rg40xx-v.dts` — the pins are all in one
`gpio-keys` node inherited from the parent, and can be overridden there.

## How this was verified

No RG40XXV was available while building this, so on-device boot is
**unverified**. What *was* verified:

- The board device tree compiles against a real Linux v6.18 tree, and the
  built DTB was inspected to confirm `model`, `compatible`, that `led-rgb`
  merges into mainline's (unlabelled) `leds` node, and that the RTL8821CS
  `wifi@1` node is inherited.
- Every kernel symbol `linux/nerves.fragment` asks for survives
  `olddefconfig`, and 41 boot-critical driver symbols are asserted present
  in the resulting config — plus an assertion that no initramfs is
  configured, since `erlinit` must be PID 1 straight out of the squashfs.
  `tools/gen-kernel-defconfig.sh` fails if any of that regresses.
- A full Buildroot build produces a flashable `.fw`.
- `mix nerves.system.lint` passes.

Treat the checklist above as the remaining half of the work.

## Building the system from source

You only need this if you are changing the system itself.

```bash
git clone https://github.com/kek/nerves_anbernic
cd nerves_anbernic
mix deps.get
mix compile          # builds via Docker on macOS, natively on Linux
```

To regenerate the kernel configuration after editing
`linux/nerves.fragment`:

```bash
tools/gen-kernel-defconfig.sh 6.18.44
```

This runs in Docker, asserts that every symbol you asked for actually took
effect, checks the boot-critical driver list, and writes
`linux/linux-6.18.defconfig`. It exits non-zero if anything is missing, so
it is safe to run in CI.

## Notes on the boot chain

```
BROM → SPL → ATF BL31 (sun50i_h616) → U-Boot → sysboot → Linux
```

Two things here are easy to get wrong and worth knowing about:

- **The kernel device tree is named explicitly** in
  `rootfs_overlay/boot/extlinux/extlinux-{a,b}.conf`. U-Boot's own built-in
  DTB is `sun50i-h700-anbernic-rg35xx-2024`, which leaves `mmc1` disabled.
  Booting on it produces a board with no WiFi and the wrong model string,
  and nothing obviously fails — so do not remove the `fdt` line.
- **Firmware updates do not rewrite the bootloader.** SPL and U-Boot are
  written only by the `complete` task, because they are not A/B redundant
  and an interrupted in-place rewrite would brick the device. If a system
  update changes U-Boot or the environment layout, re-flash the card rather
  than running `mix upload` / `mix firmware.burn --task upgrade`.

## Adding display support

Deliberately deferred, and structured so it is additive:

1. A `linux/display/` patch series: the H616 PWM controller driver,
   `panel-mipi-dpi-spi`, and the sun4i RGB-connector change.
2. Panel nodes in the board DTS, plus a `-v2-panel` variant — the RG40XXV
   shipped with two different panels, which is why ROCKNIX carries
   `sun50i-h700-anbernic-rg40xx-v-v2-panel.dts` alongside the base one.
   Whichever your unit has, the other one shows a blank or scrambled
   screen, so both need to exist and be selectable.
3. `CONFIG_DRM_*` additions in `linux/nerves.fragment`.

None of that changes the boot chain, the image layout, or anything already
described here.

## Licensing and provenance

The board device tree is derived from the ROCKNIX/Batocera
`sun50i-h700-anbernic-rg40xx-v.dts` by Philippe Simons, itself an extension
of mainline work by Ryan Walklin and Chris Morgan. It is
`GPL-2.0-only OR BSD-2-Clause`, matching upstream.

This system is structured after
[`nerves_system_mangopi_mq_pro`](https://github.com/nerves-project/nerves_system_mangopi_mq_pro),
the closest existing sunxi Nerves system.
