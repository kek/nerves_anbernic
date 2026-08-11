# Nerves System: Anbernic RG40XXV

This is the base Nerves System configuration for the [Anbernic
RG40XXV](https://anbernic.com/products/rg-40xxv) handheld — a 4", vertical,
Allwinner H700 device.

> [!NOTE]
> Not published to Hex yet, so there is no version badge and no `"~> 0.1"`
> dependency to add. Use a path or git dependency as shown below. Hex
> publication is worth doing once someone has confirmed the thing boots.

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

In the generated `mix.exs`, set `@all_targets [:rg40xxv]` and replace the
system dependency with this one:

```elixir
{:nerves_system_rg40xxv,
 path: "../nerves_anbernic", runtime: false, targets: :rg40xxv}
```

or, to pull it straight from git:

```elixir
{:nerves_system_rg40xxv,
 github: "kek/nerves_anbernic", runtime: false, targets: :rg40xxv}
```

Then:

```bash
export MIX_TARGET=rg40xxv
mix deps.get
mix firmware
mix burn
```

If `~/.nerves/artifacts` already holds a built `nerves_system_rg40xxv`,
`mix firmware` finds it and takes seconds. Building the system from source
— a machine that has never built it, or CI — takes the better part of an
hour and needs roughly 25 GB free.

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

> [!IMPORTANT]
> `mix nerves.new` generates a `config/target.exs` containing
> `{"usb0", %{type: VintageNetDirect}}`. **That interface will not come up on
> this system**, because no gadget is composed and there is no legacy
> `g_ether` module to load. `vintage_net` will simply find no `usb0`. Do not
> treat it as your way onto the device — configure WiFi, or expect to use
> UART. The generated config also lists `eth0`, which this device does not
> have at all.

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

## Verifying it on a device

Nothing here has been confirmed on a physical RG40XXV. This is the
procedure to do that. The awkward part is that the device has no pin
header, so **you have to bake your way in before you flash** — there is no
console to fall back on if you forget.

### 1. Bake in WiFi and SSH before flashing

In your app's `config/target.exs`:

```elixir
config :vintage_net,
  config: [
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [%{key_mgmt: :wpa_psk, ssid: "your-ssid", psk: "your-password"}]
       },
       ipv4: %{method: :dhcp}
     }}
  ]
```

`nerves_pack` pulls in `nerves_ssh` and `mdns_lite`, so with that config the
device should come up reachable as `nerves.local`. Make sure you have an SSH
key (`~/.ssh/id_rsa.pub` or `id_ecdsa.pub`) — that is what authorises you.

Then `mix firmware && mix burn`, writing to the slot the device boots from.

> [!WARNING]
> This destroys the stock Anbernic OS on that card. Image your original card
> first, or use a spare — the stock card is also your control experiment if
> the device shows no signs of life.

### 2. Power on and watch the power LED

This is the only feedback available without a console, and it is more
informative than it looks. `uboot/uboot.defconfig` sets
`CONFIG_SPL_SUNXI_LED_STATUS_GPIO=268`, which is PI12 — the same pin
mainline's device tree uses for the power LED. So the **SPL** lights that
LED, long before Linux.

- **LED lights** → the BROM read sector 16, accepted the image, and ran our
  SPL. Card layout and bootloader are fine; anything wrong is later.
- **LED never lights** → the SPL never ran. Wrong card slot, a bad write,
  or the BROM rejected the image. Nothing about Linux is implicated yet.
- **LED lights but nothing else happens** → SPL ran but DRAM init or
  U-Boot failed. Suspect the DRAM timings in `uboot/uboot.defconfig`, which
  are upstream's generic H700 values. This is the case that needs UART.

### 3. Get in

```bash
ssh nerves.local
```

**If this works, you have already proved a lot.** Reaching the device over
WiFi means `mmc1` was enabled, which means *our* device tree loaded rather
than U-Boot's built-in `rg35xx-2024` — that one carries no WiFi at all. So
a successful SSH rules out the failure this system was most at risk of.

Confirm it explicitly anyway:

```elixir
cmd "cat /proc/device-tree/model"     # => Anbernic RG40XX V
```

### 4. Check the buttons — the least certain thing here

The button GPIO mapping is inherited from mainline's `rg35xx-plus.dts` on
the premise that the RG40XXV is the same board family. That is a reasonable
inference, not a confirmed fact, so this is the check most likely to find
something.

List what the kernel found:

```elixir
cmd "cat /proc/bus/input/devices"
```

You should see the gamepad and volume `gpio-keys` devices. To watch actual
presses, add `{:input_event, "~> 1.4"}` to your app and:

```elixir
{:ok, _} = InputEvent.start_link("/dev/input/event0")
# press buttons, then:
flush()
```

That is the better tool because it streams into IEx without blocking. The
image also ships `evtest`, but plain `evtest` never exits and busybox here
has no `timeout`, so it will wedge an IEx session. Use its one-shot query
form instead — hold the button down and run:

```elixir
# exit status 10 means "currently pressed"
cmd "evtest --query /dev/input/event0 EV_KEY BTN_SOUTH"
```

Work through every button and check the reported codes match the physical
layout. If they don't, the fix is small: the pins live in one `gpio-keys`
node inherited from the parent DTS, and can be overridden in
`linux/sun50i-h700-anbernic-rg40xx-v.dts`.

### 5. Everything else

```elixir
# which drivers actually bound
cmd "dmesg | grep -iE 'axp717|rtw88|mmc|sunxi|panfrost'"

# battery and charger (list first -- do not assume the name)
cmd "ls /sys/class/power_supply/"
cmd "cat /sys/class/power_supply/*/capacity /sys/class/power_supply/*/voltage_now"

# LEDs, including the RGB one on PI7
cmd "ls /sys/class/leds/"

# audio
cmd "aplay -l"
cmd "speaker-test -c 2 -t sine -l 1"

# firmware metadata round-trips through the U-Boot environment
cmd "fw_printenv nerves_fw_active"
```

### 6. If it never gets far enough to SSH

Then you need UART0 — `ttyS0`, 115200 8N1, 3.3V logic, on internal test
pads, which means opening the case. Two things make that more useful:

- Drop `quiet` and add `earlycon` to the `append` line in
  `rootfs_overlay/boot/extlinux/extlinux-a.conf` to get early kernel output.
- Set `CONFIG_BOOTDELAY=1` in `uboot/uboot.defconfig` so you can interrupt
  U-Boot and get a prompt. It is 0 here for fast boot, which is the wrong
  trade-off while bringing a board up. From a U-Boot prompt you can
  `printenv`, `ls mmc 0:2 /boot`, and boot by hand.

Both need a system rebuild, so if you expect to need UART, make the changes
before the first build rather than after.

### What to report back

If something fails, the useful details are: which stage above it reached,
the full `dmesg`, and `cat /proc/device-tree/model`. Those three narrow it
down to bootloader, device tree, or driver almost immediately.

## How this was verified

No RG40XXV was available while building this, so **on-device boot is
unverified**. Everything short of that is:

**The system builds.** A full Buildroot build completes and produces
`bl31.bin`, `Image`, `sun50i-h700-anbernic-rg40xx-v.dtb`,
`u-boot-sunxi-with-spl.bin`, `uboot-env.bin`, and `rootfs.squashfs`. ATF
built for `PLAT=sun50i_h616` and its BL31 was folded into U-Boot, so the
bootloader chain is wired up rather than merely configured.

**The device tree is what it claims to be.** The DTB *as built by
Buildroot inside the real kernel tree* was decompiled and checked: model
`Anbernic RG40XX V`, compatible `anbernic,rg40xx-v`, the `led-rgb` node
merged into mainline's unlabelled `leds` node, the RTL8821CS `wifi@1` node
inherited, 17 button nodes, and no panel node.
`tools/check-dts.sh` reruns this standalone against a fresh kernel tree.

**The kernel has the drivers.** Every symbol `linux/nerves.fragment` asks
for survives `olddefconfig`, and 41 boot-critical drivers are asserted
present — plus an assertion that no initramfs is configured, since
`erlinit` must be PID 1 straight out of the squashfs.
`tools/gen-kernel-defconfig.sh` fails if any of that regresses.

**A real firmware image is produced and lands correctly on disk.**
`mix firmware` against this system produces a `.fw`
(`meta-platform=rg40xxv`, `meta-architecture=aarch64`). Applying its
`complete` task to a disk image and inspecting the result confirms:

- `eGON.BT0` at byte 8192, so the Allwinner BROM will find the SPL
- partitions at LBA 43008 / 829440 / 1615872 — i.e. `mmcblk0p2`, `p3`,
  `p4`, matching what `extlinux.conf` and `erlinit.config` expect
- rootfs A is a valid squashfs, gzip-compressed, which is the one
  compression U-Boot can actually read here
- the U-Boot environment at `0x400000` carries `nerves_fw_active=a`,
  `a.nerves_fw_platform=rg40xxv`, and the A/B `bootcmd`
- `/boot/Image`, `/boot/sun50i-h700-anbernic-rg40xx-v.dtb`, and both
  `extlinux` configs are present inside the rootfs

**The layout is self-consistent.** `tools/check-consistency.sh` asserts the
partition offsets, `CONFIG_ENV_OFFSET`, `fw_env.config`, each `root=`, and
erlinit's mount all agree. `mix nerves.system.lint` reports no failed
checks; it advises adding `e2fsprogs`, which this system deliberately omits
because the application partition is f2fs and `f2fs-tools` is what
`nerves_runtime` needs to reformat it.

What none of that proves is that the hardware comes up: the DRAM timings,
the button GPIO mapping, and USB gadget behaviour are all inherited on the
reasonable-but-unconfirmed premise that the RG40XXV matches its siblings.
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
