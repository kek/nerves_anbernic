# Nerves System: Anbernic RG40XXV

This is the base Nerves System configuration for the [Anbernic
RG40XXV](https://anbernic.com/products/rg-40xxv) handheld — a 4", vertical,
Allwinner H700 device.

> [!NOTE]
> Not published to Hex yet, so there is no version badge and no `"~> 0.1"`
> dependency to add. Use a path or git dependency as shown below.

This has been **confirmed working on a physical RG40XXV**: it boots, joins WiFi
on 5 GHz, and answers SSH over both WiFi and the USB-C cable. Getting there took
five fixes that are worth knowing about before you change anything here — see
"[What bring-up actually found](#what-bring-up-actually-found)".

| Feature              | Description                                     |
| -------------------- | ----------------------------------------------- |
| CPU                  | Allwinner H700, quad Cortex-A53 @ 1.5 GHz       |
| Memory               | 1 GB LPDDR3 @ 672 MHz — **not** LPDDR4, see below |
| Storage              | MicroSD                                         |
| Linux kernel         | 6.18.x mainline                                 |
| IEx terminal         | SSH over WiFi or USB gadget; `ttyS0` on internal pads |
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

### WiFi

Both this and the USB gadget below are confirmed working. WiFi is the one you
want in normal use; USB is easier for a first boot. `wpa_supplicant`,
`wireless-regdb` and the `rtw88` firmware are all in the image; configure it
from your application with `vintage_net_wifi`.

Two things to get right, both of which cost time to discover — see step 1 of
"Verifying it on a device" for the full config:

- **Set a real `regulatory_domain`.** The generated config ships `"00"`, the
  world domain, which marks most 5 GHz channels no-initiate-radiation. A
  5 GHz-only network is then scanned but never joined, which looks exactly
  like a wrong password.
- **Bake in an SSH host key.** `nerves_ssh` cannot generate one on OTP 29
  (see "Known limitations"), so without this the daemon never starts and the
  device is unreachable even with working WiFi.

### USB gadget over the type-C cable

**Confirmed working**, and for bringing up a new unit this is the better of the
two routes: it needs no WiFi credentials and no SSH host key baked in, and it
cannot be broken by getting the regulatory domain wrong.

Mainline sets the H700's `usbotg` node to `dr_mode = "peripheral"`, and the
kernel here is built with `USB_CONFIGFS`, `..._ECM`, `..._RNDIS` and `..._ACM`.
Nothing composes a gadget at boot — that is the application's job, as on other
Nerves gadget targets. With `{"usb0", %{type: VintageNetDirect}}` in your
config and a gadget composed via configfs, the device appears on the host as
`Nerves handheldgame` (`1d6b:0104`), serves DHCP, and answers SSH:

```console
$ ifconfig | grep 172.31
	inet 172.31.70.42 netmask 0xfffffffc broadcast 172.31.70.43
$ ssh nerves@172.31.70.41
```

Composing the gadget is a matter of writing to
`/sys/kernel/config/usb_gadget/`; note that configfs is not mounted by the
Nerves skeleton's fstab, so mount it first. CDC-ECM is the function to pick for
macOS and Linux hosts.

> [!NOTE]
> This needs `patches/linux/0002-phy-sun4i-usb-let-the-mux-route-decide-phy0-mode.patch`,
> which is in this system. Without it the gadget composes and `usb0` gets an
> address, but the host never enumerates it: `sun50i_h616_cfg` sets
> `.phy0_dual_route = true`, so the EHCI/OHCI host driver and MUSB share phy0
> and both call `phy_set_mode()` on it — the host wins, and the port sits
> electrically in host mode while the logs show
> `phy-5100400.phy.0: Changing dr_mode to 1`.

> [!IMPORTANT]
> `mix nerves.new` also generates an `eth0` entry, which this device does not
> have at all. Remove it or expect a permanently disconnected interface.

### UART0

`ttyS0` is UART0 on the PH pins, which is where the kernel's `stdout-path`
points and where `erlinit` puts IEx by default. On these handhelds it is on
internal test pads, so it means opening the case and soldering.

Settings are 115200 8N1.

It is the fullest view of a board that will not boot, but it was **not needed**
during bring-up — every bug there was diagnosed over FEL and the SD card
instead. Try "[Debugging without a console](#debugging-without-a-console)"
before reaching for a soldering iron.

## Verifying it on a device

This procedure has been run on a physical RG40XXV and the device now boots,
joins WiFi and answers SSH. It is still worth following on a new unit or after
changing the system, because most of it is unexercised by CI. The awkward part
is that the device has no pin header, so **you have to bake your way in before
you flash** — there is no console to fall back on if you forget.

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

### 2. Power on

> [!WARNING]
> **Do not read anything into the LED at power-on.** An earlier version of
> this document offered an LED-based triage tree on the reasoning that
> `CONFIG_SPL_SUNXI_LED_STATUS_GPIO=268` (PI12) is the power LED, so the SPL
> lights it before Linux. That reasoning is sound but the conclusion is not:
> on real hardware the LED glows a steady yellow whenever the device has
> power, because it is the AXP717's charge indicator. It looks identical
> whether the device booted or is wedged, and it cost hours of misdiagnosis.

The device gives no usable feedback at power-on: the panel is unsupported
(see above), so the screen stays black on a completely healthy boot. Your
application can create a signal by pointing the LEDs at the kernel's
heartbeat trigger once it starts, which is worth doing — a blinking LED then
means kernel up, BEAM up, application supervision tree up:

```elixir
File.write("/sys/class/leds/green:status/trigger", "heartbeat")
```

`/sys/class/leds` has `green:power`, `green:status`, `rgb:indicator` and
`rtw88-mmc1:0001:1`. This needs no kernel changes; `CONFIG_LEDS_GPIO` and
`CONFIG_LEDS_TRIGGER_HEARTBEAT` are already built in.

Until the application runs, use FEL instead of guessing — see
"[Debugging without a console](#debugging-without-a-console)".

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

See "Debugging without a console" below. Every bug found during bring-up was
diagnosed that way; opening the case for UART was never necessary.

UART0 remains the fullest option if you want it — `ttyS0`, 115200 8N1, 3.3V
logic, on internal test pads. Two changes make it more useful, and both need
a system rebuild, so make them before your first build if you expect to need
them:

- Drop `quiet` and add `earlycon` to the `append` line in
  `rootfs_overlay/boot/extlinux/extlinux-a.conf` for early kernel output.
  Bare `earlycon` resolves because the device tree sets
  `chosen/stdout-path = "serial0:115200n8"`.
- Set `CONFIG_BOOTDELAY=1` in `uboot/uboot.defconfig` so you can interrupt
  U-Boot. It is 0 here for fast boot, which is the wrong trade-off while
  bringing a board up.

### What to report back

If something fails, the useful details are: which stage above it reached, the
full `dmesg`, and `cat /proc/device-tree/model`. Those three narrow it down to
bootloader, device tree, or driver almost immediately.

## Debugging without a console

The device has no display, no pin header, and the LED tells you nothing. Three
techniques cover the whole boot chain without opening it.

**FEL, for anything before Linux.** The H700's BROM exposes Allwinner's USB
recovery protocol, which lives in mask ROM and therefore works even when
nothing on the card boots. Power on with **no SD card** and connect USB-C:

```bash
sunxi-fel -l                     # the H700 reports as H616, SoC ID 0x1823
sunxi-fel spl images/u-boot-sunxi-with-spl.bin   # runs our SPL, which inits DRAM
sunxi-fel readl 0x40000000       # DRAM answers => init succeeded
sunxi-fel writel 0x40000000 0xcafebabe
sunxi-fel readl 0x40000000       # round-trips => DRAM is genuinely usable
```

This is how the LPDDR3 bug was found. A device that vanishes from USB after
`spl` has hung the SoC in DRAM init. Write two addresses 1 MB apart and read
the first back to check for aliasing, which indicates wrong geometry rather
than wrong timings — that failure mode boots the SPL happily and corrupts
Linux later.

**Card breadcrumbs, for userland.** There is ~17 MB of unallocated space
between the U-Boot environment (ends block 8448) and rootfs A (block 43008).
An application can write diagnostics there with a plain `File.write` to
`/dev/mmcblk0` at a block offset, then you power off and read it on a host
with `dd`. Combined with `RingLogger`, that yields the complete boot log —
kernel messages included, because `nerves_logging` feeds kmsg into Logger.
Prefer this over the U-Boot environment: a bad write there stops the device
booting, whereas this region is only touched by a full re-flash.

**The card itself records two boot facts**, readable with `dd` and no
instrumentation at all:

- `nerves_fw_booted` in the U-Boot environment at `0x400000` flips 0 → 1 the
  first time `bootcmd` runs. It is deliberately shipped as 0 for this reason.
- The application data partition is written as `0xff` by fwup and reformatted
  to f2fs on first boot. f2fs magic at block 1615872 + 1024 therefore proves
  the kernel ran and reached erlinit's mount stage.

Together those two bracket the failure: environment untouched means U-Boot
never ran; environment updated but partition still `0xff` means the kernel
never started; both changed means the failure is in userland.

## What bring-up actually found

Five things, none of which were visible from source review.

**1. The board is LPDDR3, not LPDDR4.** This is the important one.
`configs/anbernic_rg35xx_h700_defconfig` upstream specifies
`CONFIG_SUNXI_DRAM_H616_LPDDR4`, and this system copied it verbatim on the
premise that the H700 Anbernics share a PCB family. They do not share memory.
With LPDDR4 timings the SPL hangs in DRAM init and the SoC stops responding
entirely — no console, no LED, indistinguishable from a dead device.

The correct values came from the **vendor boot0 on a muOS card** that boots
this hardware. Its `dram_para` struct at offset `0x38` declares
`dram_type = 7` (LPDDR3) and carries different drive-strength and ODT values,
while agreeing with upstream on the 672 MHz clock — which is what confirmed
the struct offset had been read correctly:

```bash
sudo dd if=/dev/rdiskN bs=512 skip=16 count=256 of=boot0.bin
# then read u32s from 0x38: clk, type, dx_odt, dx_dri, ca_dri, odt_en
```

If you ever doubt an inherited hardware parameter, that is the technique: a
firmware known to boot the hardware is ground truth in a way a sibling
board's defconfig is not. See the comment in `uboot/uboot.defconfig`, which
also records that the TPR field ordering is *inferred* rather than confirmed
against a struct definition.

**2. `pwrseq_simple` aborts instead of using its own GPIO fallback.** On 6.18
it demands a reset controller whenever a node has exactly one `reset-gpios`
entry, and returns early when it cannot get one, skipping the GPIO path
directly below it. Our WiFi node has `reset-gpios` and no `resets`, so mmc1
never initialised and `wlan0` never existed. Fixed by
`patches/linux/0001-mmc-pwrseq_simple-gpio-reset-fallback.patch`.

**3. `CONFIG_IP_ADVANCED_ROUTER` and `CONFIG_IP_MULTIPLE_TABLES` were
missing.** vintage_net gives each interface its own routing table, so without
them `VintageNet.RouteManager` crashes moments after DHCP succeeds. The
symptom is WiFi that associates, obtains a lease, deauthenticates "by local
choice", and loops — present and configured but never reachable.

**4. The LED is a charge indicator**, not a boot signal. See the warning in
step 2.

**5. The OTG phy is shared, and the host driver was winning it.**
`sun50i_h616_cfg` sets `.phy0_dual_route = true`, so the EHCI/OHCI host
controllers and MUSB share phy0 and both call `phy_set_mode()` on it. The host
won, leaving the type-C port electrically in host mode — logged as
`phy-5100400.phy.0: Changing dr_mode to 1` — while the gadget composed happily
and was assigned an address that could never carry traffic. Fixed by
`patches/linux/0002-phy-sun4i-usb-let-the-mux-route-decide-phy0-mode.patch`.

The wrong theory here is worth recording: the board DTS notes that the AXP717's
type-C role switch has no device tree binding, and that was taken as the likely
cause. It was a plausible reading of a real comment, and it was wrong. The
missing binding was not the problem; two drivers contending for one phy was.

## Known limitations

- **No display.** By design — see the top of this file.
- **No software power-off.** `CONFIG_INPUT_AXP20X_PEK` is not set and no
  power-key node exists, so Linux never sees the power button and holding it
  does nothing. Press reset and pull the card. Fixable by enabling the PMIC
  power key, or by mapping a gamepad combo (`/dev/input/event0` *is*
  registered) to `Nerves.Runtime.poweroff/0`.
- **Two kernel patches are carried**, both in `patches/linux/`: a
  `pwrseq_simple` GPIO-reset fallback without which there is no WiFi, and a
  sun4i USB phy fix without which the USB gadget never enumerates. Neither is
  upstream as of 6.18, so both need checking on a kernel bump.
- **`nerves_ssh` cannot generate host keys on OTP 29** (ssh 6.0.3): the daemon
  dies with `{:error, "No host key available"}` and then crashes in
  `:ssh_system_sup.stop_system(nil)`. Ship host keys in your application's
  `rootfs_overlay` and point `:nerves_ssh`'s `system_dir` at them.

## How this was verified

On-device boot **is** confirmed — see the top of this file. What follows is the
build-time verification reached *before* any hardware was available. It is kept
because CI still enforces all of it on every change, and because the gap between
it and reality turned out to be the instructive part:

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

**What all of that missed is the useful part.** Every artifact above was
well-formed and internally consistent, and none of those checks predicted any
of the four things that actually stopped the board — a DRAM type, a driver's
early-return, two absent kernel symbols, and the colour of a LED. Well-formed
is not the same as correct, and the distance between them is the size of the
hardware you do not have.

The "matches its siblings" premise held for the PMIC, mmc0, the gamepad and
WiFi, and broke for DRAM. Of the inherited assumptions, the button GPIO mapping
is the one still unexercised.

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

Deliberately deferred, and structured so it is additive. There is a working
plan for it in
[`docs/superpowers/specs/2026-08-12-display-support-plan.md`](docs/superpowers/specs/2026-08-12-display-support-plan.md),
covering the develop/test loop, what to set up before starting, and the order
to add nodes in so each step gives a distinct signal. The shape:

1. A `linux/display/` patch series: the H616 PWM controller driver,
   `panel-mipi-dpi-spi`, and the sun4i RGB-connector change.
2. Panel nodes in the board DTS, plus a `-v2-panel` variant — the RG40XXV
   shipped with two different panels, which is why ROCKNIX carries
   `sun50i-h700-anbernic-rg40xx-v-v2-panel.dts` alongside the base one.
   Whichever your unit has, the other one shows a blank or scrambled
   screen, so both need to exist and be selectable.
3. `CONFIG_DRM_*` additions in `linux/nerves.fragment`, plus the two
   `.panel` firmware blobs into `/lib/firmware/panels/` — the panel timings and
   init sequence live there, not in the device tree, and omitting them gives no
   picture and no error. See
   [the panel spec](docs/superpowers/specs/2026-08-12-display-panel-spec.md).

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
