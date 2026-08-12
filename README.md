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
| **Display**          | **Pipeline works; panel shows no image yet**    |

## The display, and what is actually known about it

The 4" LCD pipeline **works and is confirmed on hardware**. The panel does
**not yet show an image**: it displays a uniform colour that does not change
when the framebuffer is written. Everything below distinguishes what is
measured from what is not, because on this board "no picture" covers at least
four unrelated failures and the screen is the thing under test.

### What is measured, on hardware

- `/sys/class/drm/card0` and `card0-DSI-1` exist; `/dev/fb0` exists.
- Connector `connected`, `enabled`, DPMS `On`, mode 640×480, physical size
  81×61 mm (read out of the panel blob).
- dmesg: blob `loaded successfully`; all three components bound (`mixer`,
  `tcon-top`, `lcd-controller`); `[drm] Initialized sun4i-drm`;
  `Console: switching to colour frame buffer device 80x30`.
- Clock tree: `tcon-lcd0` enabled at 81 MHz with **`tcon-data-clock` at
  27 MHz** — the TCON really is clocking pixels out.
- `vdd-lcd` (the PI15 rail) and `vcc-io` (bank D) both enabled; **backlight
  physically lit**, so `gpio-backlight` on PD28 and active-high are both right.
- DRM atomic state: `plane-1` attached to `crtc-0` with fbcon's `XR24`
  640×480 buffer, pitch 2560. No errors anywhere in dmesg — no SPI warnings,
  no DRM warnings.

### What is wrong, and what that rules out

Writing a full screen of solid red into `/dev/fb0` — the very buffer DRM says
it is scanning out — does not change what the panel shows. So:

- **The SPI command channel works.** The v1 blob gave a blank screen and the v2
  blob gives a uniform colour; the panel's behaviour changed when the init
  sequence changed. That also means the SPI pin *roles* are right, which was
  the least-evidenced part of the wiring.
- **The panel is not the problem, and neither is DRM.** Every software-visible
  layer is correct. Pixels are being clocked at the right rate with the right
  timings, and the panel is receiving a constant value rather than frame data.
- **So the fault is in the DE→TCON data path, below what DRM can see.**

The DE33 top-block registers are now decoded from Allwinner's own sun50iw9 BSP
in [the DE33 register
decode](docs/superpowers/specs/2026-08-13-de33-register-decode.md). The fact
that matters: `0x1008104` is the mixer's global **status** register and its
bit 0 is the **frame-end latch**. A working muOS has it set and this tree does
not, so the display engine here has never completed a frame. That is a
one-register-read pass/fail signal, and a better thing to chase than the colour
of the screen.

The prime suspect is upstream's DE33 mixer support itself. Mainline has the
DE33 mixer and clock drivers but **no H616 display device tree at all** — not
even in master — so that code path has never been exercised by an upstream
board. ROCKNIX carries a *newer* refactor of the same author's work that moves
plane handling out of the mixer into a separate `sun50i_planes` driver, and
ROCKNIX's stack is the one with field evidence behind it. This tree chose
upstream's mixer on the principle of not reverting working upstream code (see
`patches/linux/0100`'s header); the evidence above suggests that principle
picked the wrong side here, because the upstream code may be incomplete without
the plane split rather than merely older.

**Next step, therefore: adopt ROCKNIX's planes driver** — the `sun50i_planes`
driver plus its `sun8i_mixer`, `sun8i_vi_layer` and `ccu-sun8i-de2` changes,
and its device tree layout with a separate `planes@100000` node and the mixer
carrying only its `display` and `top` windows. That is roughly seven hunks that
0100 deliberately dropped. The register windows themselves are already known
good: `top` is `0x8100`/`0x40` and `display` is `0x280000`/`0x20000`, which
match `sun8i_top_regmap_config` (`max_register 0x3c`) and
`sun8i_disp_regmap_config` (`0x20000`) exactly.

The pipeline is:

```
mixer0 -> tcon_top -> tcon_lcd0 -> panel   (RGB888 pixels + SPI init sequence)
```

Verified without hardware: the patch series applies cleanly to 6.18.44 in the
real Buildroot flow; the kernel builds; the DTB compiles with no new `dtc`
warnings and passes fourteen pipeline assertions in `tools/check-dts.sh`;
`panel-mipi.ko`, `sun4i-drm.ko`, `sun4i-tcon.ko`, `sun8i-mixer.ko`,
`sun8i_tcon_top.ko` and `gpio_backlight.ko` are all built; and both panel
blobs are installed in the target rootfs.

Not verified: that any of it produces light.

### This is a smaller job than it used to be

The design notes and the older text here said "roughly 23 kernel patches",
following ROCKNIX. That is out of date. **6.18.44 already carries the H616
DE33 mixer and its clocks** — `allwinner,sun50i-h616-de33-mixer-0` and
`-de33-clk` are upstream, and `sun8i-mixer.ko` was already being built before
any of this. What is genuinely missing upstream is the TCON support, the panel
driver, and the device tree.

So this tree carries **five** patches, not seven and not twenty-three, in
`patches/linux/0100`–`0104`. Each has a header explaining its upstream status.

ROCKNIX also carries a *newer* refactor that moves plane handling out of the
mixer into a separate `sun50i_planes` driver. That is deliberately **not**
taken: 6.18.44 implements DE33 planes inside the mixer, and adopting ROCKNIX's
version would mean reverting working upstream code. The visible consequence is
in the device tree — the mixer node uses upstream's binding,
`reg-names = "layers", "top", "display"`, and must *not* have a separate
`planes@` node. Both are asserted by `tools/check-dts.sh`, because getting it
wrong yields a mixer that probes and a screen that stays dark.

### The panel description is a firmware blob

The generic panel driver carries no panel data. It builds a filename from the
panel node's first `compatible` string and reads **both the timings and the
controller init sequence** out of `/lib/firmware/panels/<compatible>.panel`.
There is no `panel-timing` node anywhere; do not look for one.

A correct kernel and a correct device tree, without that blob, give **no
picture and no error**. Both variants ship in
`rootfs_overlay/lib/firmware/panels/`, and `tools/check-consistency.sh`
asserts that the spelling in the DTS matches a file that exists, since nothing
checks it at build time.

### Which panel this unit has

`anbernic,rg40xx-v2-panel`, and the DTS says so.

v1 was tried first, on the strength of muOS naming this hardware's panel
`fog_fj035fhd05_v1`. It produced a blank screen. v2 produces a uniform colour
instead — a different result, which is how we know the init sequence reaches
the panel at all. Since ROCKNIX's `rg40xx-v` default *is* the v1 panel and it
also shows nothing on this unit while muOS works, the vendor's `_v1` and
ROCKNIX's `-v2-panel` evidently do not refer to the same revision split.

Neither variant produces an image yet, so this is not settled — but it is no
longer a coin flip, and it is one string to change back.

Two traps when reading the log here:

- Both variants report 640×480 @ 60 Hz with identical active area, so **a
  correct mode confirms nothing about the variant.** What differs is the init
  sequence, the sync polarity (v2 `0x5` = PHSYNC|PVSYNC against v1 `0x0a` =
  NHSYNC|NVSYNC) and the reset/init delays.
- The v1 blob adds a second mode, 640×480 @ 120 Hz, and v2 does not. Two
  modelines in dmesg therefore tells you which **file** loaded — not which
  panel is soldered on.

### Backlight: GPIO, not PWM

`gpio-backlight` holds PD28 high, which is full brightness. The backlight is
really PWM-driven — muOS runs it at 50 kHz — but the H616 PWM controller has no
mainline driver and carrying the out-of-tree one costs about 1900 lines of
patch for brightness control alone. ROCKNIX's own series drives it as a plain
GPIO before switching to PWM, so this buys first light for nothing.

PD28 is the right pin from two directions: muOS's vendor DT for this device
sets `lcd_pwm_ch = 0` and muxes `pwm0` onto PD28, and PD28 is the only pin in
6.18.44's H616 pinctrl carrying a `pwm0` function.

### muOS is the reference, not ROCKNIX

muOS demonstrably drives this panel. Its vendor DT for `rg40xx-v` independently
confirms the wiring — `lcd_gpio_0..4` are PI9, PI10, PI8, PI14, PI15, exactly
the SPI clock, MOSI, chip select, reset and panel supply used here.

Where the two disagree is timings, and muOS's are the proven ones:

| | muOS (vendor) | ROCKNIX (`.panel`) |
|---|---|---|
| Pixel clock | 24 MHz | 27 MHz |
| Total | 768 × 521 | 750 × 600 |
| Refresh | 59.98 Hz | 60.00 Hz |

Since timings live in the blob rather than the device tree, preferring muOS's
means authoring a `.panel` file. That is the documented fallback if ROCKNIX's
blob gives a picture that is present but wrong. The init sequence cannot be got
from muOS at all — it lives in Anbernic's prebuilt vendor kernel, not in any
MustardOS repository.

### The screen is now a console

`CONFIG_DRM_FBDEV_EMULATION` and `CONFIG_FRAMEBUFFER_CONSOLE` are on, and both
`extlinux` configs pass `console=tty0` with no `quiet`. This matters beyond
graphics: this board has no usable console — UART0 is on internal test pads —
so until now the only way to see why a boot failed was reading raw card
sectors. See "[Debugging without a console](#debugging-without-a-console)",
most of which this obsoletes once the panel is confirmed.

HDMI is still not described. The SoC nodes exist upstream and ROCKNIX
describes the connector, but nothing here needs it and every node left out is
one that cannot fail.

The GPU is not disabled — `panfrost` builds and the Mali node is enabled.
`panfrost … error -110` in `dmesg` was a deferred-probe timeout in the headless
build and may now clear; do not chase it before the panel works.

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

The device gives no usable feedback at power-on: historically the panel was
unsupported, so the screen stayed black on a completely healthy boot. The
display is now described and the kernel log is routed to it, which should
replace most of this section — but that is unconfirmed on hardware, so treat
everything below as still current until someone has watched it boot. Your
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

- **The display pipeline works but the panel shows no image.** DRM comes up,
  the backlight lights, and the TCON clocks pixels at 27 MHz, but the panel
  displays a uniform colour that does not follow the framebuffer. The suspect
  is upstream's DE33 mixer, which no upstream board exercises. See the top of
  this file for the measurements and the proposed next step.
- **No HDMI.** The SoC nodes are upstream but nothing here describes the
  connector.
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
inherited, and 17 button nodes. It also checks the whole display pipeline —
display engine, DE33 bus and clocks, mixer, TCON TOP, TCON LCD, panel, its
generic fallback, the bit-banged SPI command channel, the backlight and the
RGB888 pinmux — and asserts the mixer uses upstream's three-window binding
with no ROCKNIX `planes@` node, since that combination probes cleanly and
still gives a dark screen. `tools/check-dts.sh` reruns this standalone
against a fresh kernel tree.

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

## Confirming the display

The parts listed as future work here are now in the tree; see "The display, and
what is actually known about it" at the top. What is left is looking at the
screen, and reading the result correctly. The plan in
[`docs/superpowers/specs/2026-08-12-display-support-plan.md`](docs/superpowers/specs/2026-08-12-display-support-plan.md)
still describes the loop and the panel spec is in
[the panel spec](docs/superpowers/specs/2026-08-12-display-panel-spec.md);
both predate the discovery that the DE33 mixer is already upstream, so their
patch counts are too high.

`mix upload`, reboot, then read it in this order. Each line distinguishes
failures that look identical on the device:

| Observation | Meaning |
|---|---|
| No `/sys/class/drm/card0` | Almost always the panel driver, not the display engine. `panel_mipi` cannot autoload and cannot be built in, so check that `erlinit.config` still has its `--pre-run-exec` modprobe. sun4i's component master cannot complete without the panel, so `/sys/class/backlight` appearing while `card0` does not is exactly this |
| `card0` exists, no connector | The panel node is not binding — check `dmesg` for `panel-mipi` and for a `request_firmware` failure on `panels/anbernic,rg40xx-v2-panel.panel` |
| Correct mode, screen black | Backlight, or the init sequence never ran. Check `/sys/class/backlight/backlight` exists and that the blob loaded |
| Correct mode, uniform colour that ignores the framebuffer | **Where this tree is now.** Write a screen of solid red into `/dev/fb0` and see whether it changes; if not, the DE→TCON path is not carrying frame data and the panel is not at fault. See the DE33 discussion at the top |
| Correct mode, scrambled or rolling | **Wrong panel variant.** One string in the DTS; see above. Not wrong timings |
| Correct mode, correct image | Done. Update the hardware table and delete the hedging at the top of this file |

Useful commands, all of which took a while to work out. SSH into this device
runs **Elixir, not a shell**, so `System.cmd` needs absolute paths and `uname`
is not even on `PATH`:

```elixir
# The pixel clock -- proof the TCON is scanning out at all. debugfs is not
# mounted by default.
System.cmd("/bin/mount", ["-t", "debugfs", "none", "/sys/kernel/debug"])
File.read!("/sys/kernel/debug/clk/clk_summary")      # look for tcon-data-clock

# What DRM believes it is doing: plane, framebuffer, format, CRTC, mode.
File.read!("/sys/kernel/debug/dri/0/state")

# Does anything reach the panel? Solid red, XRGB8888.
File.write("/dev/fb0", :binary.copy(<<0, 0, 255, 0>>, 640 * 480))

# Read a display-engine register directly. muOS has devmem at the same path,
# so the same command compares a working configuration against this one.
System.cmd("/sbin/devmem", ["0x11C1010", "32"])   # UI layer 0 framebuffer address
```

`devmem` is here because `busybox/busybox.fragment` re-enables it —
nerves-common's busybox config turns it off, and its absence is what stopped a
debugging session. Registers owned by a driver can also be read through
`/sys/kernel/debug/regmap/1100000.mixer-{layers,top,display}`, but the DE clock
window at `0x1008000` has no regmap, so `devmem` is the only way to see it.
[The DE33 register
decode](docs/superpowers/specs/2026-08-13-de33-register-decode.md) lists the
addresses worth reading, with the values to expect.

`modetest` needs stdin held open or it drops the mode as it exits:

```
sleep 300 | modetest -M sun4i-drm -s 53:640x480
```

`libdrm`'s test tools ship for exactly this: `modetest` enumerates connectors,
CRTCs and modes and can draw a test pattern without the application running.

Because `console=tty0` is on the kernel command line, a successful boot should
also put the kernel log on the panel — which is the cheapest possible proof,
requiring no userspace at all.

None of this changed the boot chain or the image layout.

## Licensing and provenance

The board device tree is derived from the ROCKNIX/Batocera
`sun50i-h700-anbernic-rg40xx-v.dts` by Philippe Simons, itself an extension
of mainline work by Ryan Walklin and Chris Morgan. It is
`GPL-2.0-only OR BSD-2-Clause`, matching upstream.

This system is structured after
[`nerves_system_mangopi_mq_pro`](https://github.com/nerves-project/nerves_system_mangopi_mq_pro),
the closest existing sunxi Nerves system.
