# Plan: verifying what was inherited but never tested

**Date:** 2026-08-16
**Status:** Phase 1 has been run against the device. Results are recorded
against each item below. Phase 2 needs a person holding the board, and
`scenic_rg40xxv` now puts those readings on the panel so that it only needs
one.

Phase 1 found three passes and one real failure. The failure is Bluetooth,
and it is the same shape as everything else in the table below: an `hci0`
exists, so every cheap check says yes, and the controller has in fact been
dead since the first boot.

Phase 2 has since been done by hand. Battery charge/discharge, the volume
buttons and headphone detect all pass. Only audibility is left, and it is
waiting on a decision rather than on evidence.

Two things in this document turned out to be wrong, and both are corrected
in place rather than deleted: the pass criterion for Bluetooth, and the
claim that the X and Y buttons needed no translation. A plan whose errors
are edited out silently teaches nothing the second time.

## Why this exists

This system's characteristic failure mode is not bad code. It is **inherited
assumptions that were reasonable and wrong**, and they have been expensive
every time:

| Assumption | How it failed |
|---|---|
| The RG40XXV is the same PCB family as the RG35XX Plus, so upstream's LPDDR4 timings apply | SPL hangs during DRAM init. The SoC stops responding — no FEL, no console, nothing |
| A DPI panel endpoint does not need `reg` | Mixer routed to TCON2 while the panel is on TCON0. Uniform green screen, no error logged anywhere |
| muOS naming `fog_fj035fhd05_v1` means ROCKNIX's non-`-v2` blob | Blank panel with the backlight on |
| Panfrost is enabled, so the GPU works | Probe deferred and died `-110`. `card0` still present, so nothing looked broken |

Note what these have in common: **the system reports success.** Three of the
four produced no error at all. That is why "it boots" is not evidence, and why
each item below names the *command* that distinguishes working from
plausible-looking.

`nerves_defconfig` already admits the debt in as many words:

> the button GPIO mapping and the audio routing are inherited from mainline's
> `rg35xx-plus.dts` on the premise that the RG40XXV is the same board family,
> and nothing here has been confirmed on hardware

Buttons are now confirmed. Audio is not.

## Method

For each item: **one command, a stated pass, and a stated fail.** Writing down
the failure first is the point — otherwise an ambiguous result gets read as a
pass, which is exactly how the panel variant stayed open for two attempts.

Where a failure has more than one cause, the plan says how to tell them apart.
"No sound" covering both a wrong DT and a muted mixer is not a result.

Order is cheapest-and-most-load-bearing first. Everything in phase 1 is
read-only.

---

## Phase 1 — read-only, no reboot, five minutes

Nothing here changes device state. All of it can run in one SSH session.

### 1.1 Battery and charging

Configured (`CONFIG_BATTERY_AXP20X=y`, `CONFIG_AXP20X_POWER=y`), never read.
A handheld that cannot report charge is not finished.

```elixir
File.ls!("/sys/class/power_supply")
File.read!("/sys/class/power_supply/axp20x-battery/capacity")
File.read!("/sys/class/power_supply/axp20x-battery/status")
```

- **Pass:** a supply exists, `capacity` is 0–100 and plausible, `status` moves
  between `Charging` and `Discharging` when the cable is pulled.
- **Fail — no supply directory:** the driver did not bind. DT node missing or
  not wired to the PMIC.
- **Fail — supply exists, `capacity` reads 0 or 100 always:** the driver bound
  but the fuel gauge is not calibrated for this pack. Worse than absent,
  because it looks right.

The cable test matters: a static plausible number is the failure that passes
inspection.

**Result: pass.** Both supplies are present, `axp20x-battery` and
`axp20x-usb`. The battery reported `capacity 83`, `status Charging`,
`voltage_now 4192000`, `current_now 1747000`, `health Good`.

The static-number failure is ruled out without needing the cable: capacity
went 83 → 84 between two runs a few minutes apart, and the current moved
1747000 → 1721000 → 1657000 across three. It is a live gauge, not a constant.

**Cable test: pass, confirmed by hand.** `status` reads `Charging` with the
cable in, `Discharging` when it is pulled, and `Charging` again when it goes
back. Both directions, so this is a real supply state and not a boot-time
constant. Battery is fully verified.

### 1.2 Thermal

`CONFIG_SUN8I_THERMAL=y`, never read. Relevant now that the GPU is real —
Panfrost at load is the first thing on this board that will make heat.

```elixir
Path.wildcard("/sys/class/thermal/thermal_zone*/type")
Path.wildcard("/sys/class/thermal/thermal_zone*/temp")
```

- **Pass:** at least one zone, `temp` in the 30000–60000 range (millidegrees),
  and it *rises* under load.
- **Fail — no zones:** driver did not bind.
- **Fail — constant value:** sensor is not being read. Check it moves; a fixed
  number is not a temperature.

Load it with `kmscube` (press A) and re-read. No rise means no real sensor.

**Result: pass, including the part that needed load.** Four zones, and they
were driven rather than merely read — 45 seconds of busy loops on all four
schedulers, sampled before and after:

| Zone | Idle | Loaded | Δ |
|---|---|---|---|
| `cpu-thermal` | 47.9 °C | 57.7 °C | **+9.8** |
| `ve-thermal` | 46.8 °C | 53.8 °C | +7.0 |
| `gpu-thermal` | 47.6 °C | 53.5 °C | +5.9 |
| `ddr-thermal` | 47.5 °C | 53.3 °C | +5.8 |

`cpu-thermal` moving most under a CPU load is the detail that makes these
real sensors rather than one value copied to four files.

### "Load it with kmscube and re-read" was bad advice

That instruction is struck. Tested by hand: 30 seconds of kmscube left
`gpu-thermal` at 46 °C, unchanged. Read literally, the plan says that is a
dead sensor. It is not.

Measured directly instead, using panfrost's per-engine busy counters, which
need `1` written to `/sys/devices/platform/soc/1800000.gpu/profiling` before
`fdinfo` reports anything:

| Engine | Busy over 30 s | Utilisation |
|---|---|---|
| `drm-engine-fragment` | 1.43 s | **4.74 %** |
| `drm-engine-vertex-tiler` | 0.15 s | 0.51 % |

`gpu-thermal` moved 45.26 → 45.91 °C across the same window, which is noise.

So a vsync-limited spinning cube at 640×480 is about 5% of a Mali-G31 and
cannot produce measurable heat. The sensor was already proven by the CPU
load above; the *test* was wrong. Temperature is a poor proxy for "is the
GPU working" and the fdinfo counters are a direct answer, so the diagnostics
screen now shows utilisation and no longer claims the temperature should
rise.

Worth recording, since this is the second time an expectation written into
this document has been the thing at fault rather than the hardware.

### Two absences found while looking

Neither is a failure, but both are unknowns that were not on the list:

* `/sys/class/devfreq` is **empty** — the GPU has no frequency scaling. It
  runs at a fixed clock, so there is no DVFS to observe or tune.
* `/sys/class/thermal/cooling_device*` is **empty** — there is no thermal
  throttling bound to any zone. The only trip point on `gpu-thermal` is
  `critical` at 110 °C, which is a shutdown, not a governor.

At ~5% GPU load and 46 °C this is academic. It stops being academic under
an emulator, which is the point of the device.

### 1.3 RTC

`CONFIG_RTC_DRV_SUN6I=y`. Nerves sets `update_clock: true`, so a broken RTC is
masked by NTP once the network is up — and unmasked on every boot before it.

```elixir
File.ls!("/sys/class/rtc")
System.cmd("hwclock", ["-r"])
```

- **Pass:** `rtc0` exists and reads a sane time.
- **Fail:** no `rtc0`, or a time near the epoch. Means timestamps before NTP
  are meaningless — including the boot report's.

Worth knowing whether the board even has a backup cell; if not, "fails across
power cycles" is expected rather than a bug.

**Result: pass — but `hwclock` is not in the image.** The command this plan
specified does not exist on the device, which is worth saying plainly: a
verification step that cannot be run is not a step. sysfs answers it anyway:

    rtc0/name        sun6i-rtc 7000000.rtc
    rtc0/date        2026-08-15
    rtc0/time        23:24:51
    rtc0/hctosys     1

`hctosys 1` is the load-bearing line. It means the kernel used this RTC to
set the system clock at boot, so the RTC held a sane time *before* the network
came up — which is the only part NTP cannot fake afterwards. The reading also
matched `NaiveDateTime.utc_now()` to the second.

Whether it survives a power cycle is still open, and needs the device off.

### 1.4 Bluetooth presence

`CONFIG_BT=m` with `BT_HCIUART_RTL=y`. The boot report already shows the
`bluetooth` module loaded, which proves nothing about the controller.

```elixir
File.ls("/sys/class/bluetooth")
System.cmd("hciconfig", ["-a"])
```

- **Pass:** an `hci0` exists.
- **Fail — module loaded, no `hci0`:** the RTL8821CS BT side never attached.
  Distinct from "no driver": the WiFi half of this chip works, so the shared
  firmware is present and the UART/enable path is the suspect.

Stop here in phase 1. Pairing is phase 2.

**Result: fail — and the stated pass criterion was wrong.**

An `hci0` does exist under `/sys/class/bluetooth`. By the criterion written
above that is a pass, and it is not: the controller is dead. This plan set out
to name the command that separates working from plausible-looking and then,
on this item, named a plausible-looking one. Worth keeping visible.

Two things gave it away. The `hci0` directory has no `address` attribute,
which a controller that finished setup would have. And `dmesg` says so
outright:

    Bluetooth: hci0: RTL: loading rtl_bt/rtl8821cs_fw.bin
    Bluetooth: hci0: RTL: loading rtl_bt/rtl8821cs_config.bin
    bluetooth hci0: Direct firmware load for rtl_bt/rtl8821cs_config.bin
                    failed with error -2
    Bluetooth: hci0: RTL: mandatory config file rtl_bt/rtl8821cs_config
                    not found

The chip needs two blobs. `rtl8821cs_fw.bin` is on the device;
`rtl8821cs_config.bin` is not, and `btrtl` treats it as mandatory, so setup
aborts. The suspicion recorded above — that the shared firmware is present
because the WiFi half works — was right about the chip and wrong about the
file.

### Why the file is missing

Not a board problem. linux-firmware ships no such *file*; `WHENCE` declares
it as a symlink:

    Link: rtl_bt/rtl8821cs_config.bin -> rtl8761b_config.bin

Buildroot packages the glob `rtl_bt/rtl88*.bin` for
`BR2_PACKAGE_LINUX_FIRMWARE_RTL_88XX_BT`, then recreates `WHENCE` symlinks
**only where the target was packaged**. `rtl8761b_config.bin` does not match
`rtl88*`, so the link is skipped silently. No warning, no build failure.

### The fix, and how it was checked without a rebuild

`BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT=y` lists `rtl_bt/rtl8761b_config.bin`
explicitly. One line in `nerves_defconfig`; the comment there has the detail.

Buildroot's install step was then simulated against the real `WHENCE` and the
real globs, and the simulation was calibrated before being trusted. Run
against the *current* config it predicts exactly two created symlinks —
`rtl8723d_config.bin` and `rtl8821a_config.bin` — and those are exactly the
two on the device, present for the same reason (they point at
`rtl8821c_config.bin`, which `rtl88*` does match). A model that reproduces
the observed state, run with the fix, produces
`rtl8821cs_config.bin -> rtl8761b_config.bin`.

**Since built, and the prediction held.** The system was rebuilt with the
`87XX` option and the rootfs contains exactly what the simulation said it
would:

    rtl8761b_config.bin                    25 bytes, real file
    rtl8821cs_config.bin -> rtl8761b_config.bin

So the blob the driver called mandatory is now in the image. What remains is
flashing it and reading `hci0`: an `address` attribute where there was none,
and no `-2` in `dmesg`. The diagnostics screen shows all three of `hci0`,
`address` and the config blob, so that is a glance rather than a session.

**Still unconfirmed:** that the controller actually comes up. Shipping the
file the driver asked for is not the same as the driver being happy with it,
and this document has already been caught once treating a necessary
condition as a sufficient one.

### What the rebuild cost, and a Buildroot trap worth keeping

Two things bit, neither related to Bluetooth.

`patches/buildroot/0001-…` **did not apply at all.** Its hunk headers
disagreed with their bodies — `@@ -205,11 +203,9 @@` over a body of 10 and 8
lines — so `patch` rejected the whole file. The README's instruction to
reapply it after `mix deps.get` could never have worked. It has been
regenerated with `diff -u` and verified against a pristine tree.

Then Mesa built **without GBM**, and kmscube failed with
`Dependency "gbm" not found`. The cause is worth remembering: the first build
ran before the patch was fixed, so panfrost was disabled and Mesa was built
and stamped without GBM. Fixing the patch corrected `.config` —
`BR2_PACKAGE_MESA3D_GBM=y` was there and verified — but **Buildroot does not
reconfigure a package that is already stamped built.** Deleting
`build/mesa3d-26.1.2` and rebuilding fixed it.

Reading `.config` would have said the build was correct. Only the artifact
said otherwise, which is the same lesson as the rest of this document.

### A second gap, not yet decided

There is no BlueZ in the image — `hciconfig`, `bluetoothctl`, `btmgmt` and
`btattach` are all absent. Even with the firmware fixed, nothing in userspace
can bring the controller up or pair anything. Choosing between
`bluez5_utils` (large, needs D-Bus) and an Elixir-side stack is a real
decision about the platform, so it is left open rather than settled here.

---

## Phase 2 — needs hardware interaction

### 2.1 Audio — the big one

Inherited from `rg35xx-plus.dts`, never exercised, and `aplay`, `amixer` and
`speaker-test` were put in the image *specifically* for this. It is a games
device; audio is not optional.

```elixir
System.cmd("aplay", ["-l"])
System.cmd("amixer", ["scontrols"])
System.cmd("speaker-test", ["-c", "2", "-t", "wav", "-l", "1"])
```

- **Pass:** a card is listed, and sound comes out of the speaker.
- **Fail — no card from `aplay -l`:** the codec driver did not bind. Check
  `SND_SUN4I_CODEC` and `SND_SUN8I_CODEC_ANALOG` actually loaded; both are
  modules here, and the panel driver has already taught us that a module which
  does not autoload looks identical to one that is missing.
- **Fail — card listed, silence:** **do not conclude the routing is wrong.**
  The overwhelmingly likely cause is that the ALSA mixer defaults to muted.
  Check `amixer scontrols` and unmute every switch before blaming the DT.

Then, and only then, is silence evidence about the device tree.

Headphone detect is a separate check — `H616 Audio Codec Headphone Jack` is
already registered as an input device (`event2`), so plugging a jack should
produce a switch event. That it enumerates says the DT describes it; it does
not say the detect pin is right.

**Half of this is already answered, silently.** No sound has been played.

The codec bound. `aplay -l` lists *card 0: Codec [H616 Audio Codec]*,
`/dev/snd/pcmC0D0p` exists, and `sun4i_codec` is loaded. That removes the
first failure mode entirely — this is not another module that quietly failed
to autoload.

And the prediction about the mixer was right, which matters because it is the
thing that would have been misread:

| Control | State |
|---|---|
| `Speaker` | on |
| `DAC` | 100%, switch **off** |
| `Line Out` | **0%**, switch **off** |
| `DAC Reversed` | off |

So the device is muted at the mixer *right now*. Had `speaker-test` been run
first, it would have produced silence, and silence would have looked like
evidence about the device tree. It would have been evidence about a default.

What is left is genuinely only: unmute, play, listen. `ScenicRg40xxv.Audio`
does exactly that in one step — and refuses unless
`config :scenic_rg40xxv, audio_test: true`, which is `false`. Nothing plays
until someone sets it.

**Headphone detect: pass.** Plugging a jack in is detected. So the DT does
not merely describe the jack, the detect pin is wired and reports. That is
the half of audio that could be checked without making noise, and it is
done.

### 2.2 Volume buttons

`gpio-keys-volume` is on `event1`, separate from the gamepad, and unlike the
gamepad it is **not** verified. It carries a `kbd` handler, so it emits normal
key codes.

```elixir
InputEvent.start_link("/dev/input/event1")
# press volume up/down, then:
flush()
```

- **Pass:** distinct events for up and down.
- **Fail:** no events, or both buttons the same code.

Read the expected codes from the DT first, the way the gamepad map was
derived — `/sys/firmware/devicetree/base/gpio-keys-volume/*/linux,code`. Do
not assume `KEY_VOLUMEUP`; the gamepad taught us the obvious guess can be
wrong in a way nothing reports.

**Codes read, presses still needed.** From the device tree:

    button-vol-down   "Key Volume Down"   114   KEY_VOLUMEDOWN
    button-vol-up     "Key Volume Up"     115   KEY_VOLUMEUP

This time the obvious guess was right — which is only known because it was
checked.

**Result: pass.** Both directions register presses.

### X and Y are swapped too, and this document said they were not

The paragraph that stood here claimed X (307) and Y (308) needed no
translation, because the device tree labels them `Action-Pad X` and
`Action Pad Y` and Linux has `BTN_X == BTN_NORTH == 307` and
`BTN_Y == BTN_WEST == 308`. Self-consistent, and wrong.

Pressing them settles it: the button silkscreened **X** emits 308 and the
one silkscreened **Y** emits 307. The device tree's X/Y labels are the wrong
way round for this shell — the same trap as A and B, in a document that had
just finished warning about that exact trap. Reading the device tree is not
the same as pressing the button.

Confirmed on the gamepad at the same time: `Action-Pad A` is 305
(`BTN_EAST`) and `Action-Pad B` is 304 (`BTN_SOUTH`), as
`ScenicRg40xxv.Launcher` documents.

### 2.3 Charging behaviour under load

Only meaningful after 1.1 passes. Run `kmscube`, on battery, and watch capacity
over ten minutes. Establishes whether the GPU can outrun the charger, which
matters for a handheld that is supposed to play games while plugged in.

---

## Phase 3 — changes, each its own commit

### 3.1 Software power-off

Known gap, already diagnosed in the README: `CONFIG_INPUT_AXP20X_PEK` is not
set and no power-key node exists, so Linux never sees the power button.

Two routes:

1. Enable `CONFIG_INPUT_AXP20X_PEK` and add the PMIC power-key node. The
   proper fix.
2. Map a gamepad combo to `Nerves.Runtime.poweroff/0`. Pure app code, no
   system rebuild, and now trivial — `ScenicRg40xxv.Launcher` already reads
   the gamepad.

Do (2) first. It is minutes rather than a Buildroot cycle, and it tells you
whether `poweroff/0` even brings the board down cleanly on this hardware —
which is the part that is actually unknown. Then do (1) properly.

**Route (2) is done, unpressed.** Hold Select and press Menu
(`BTN_SELECT` 314 + `BTN_MODE` 316) and `ScenicRg40xxv.Launcher` calls
`Nerves.Runtime.poweroff/0`. A chord rather than a button because it is not
undoable and this is a handheld that gets carried in a pocket.

Deliberately not tested from here. It would have put the device down with
nobody near it, and the only way back is the power button. Route (1) is still
the proper fix and still open.

### 3.2 Kernel config trimming

The fragment says the base is the stock arm64 defconfig and *"trimming it is
follow-on work"*. Affects image size and boot time, and the rootfs partitions
in `fwup_include/fwup-common.conf` are sized for the current bloat.

Not urgent, and genuinely risky: this config is the one the RG35XX-family DTs
were developed against, so every removal is a small version of the same
inherited-assumption bet. Trim only with a test that proves the removed thing
was unused.

### 3.3 HDMI

SoC nodes are upstream; nothing describes the connector. Unknown whether the
port is even wired on this board. Cheapest first step is to look at the shell,
not the DT.

---

## Standing checks, not one-offs

**CI.** Last green at `74cf4b9`; trunk is many commits past that. Get it green
before adding more. It is also the only thing that will catch the Buildroot
patch problem below.

**`patches/buildroot/0001-…` is not applied automatically.** `mix deps.get`
replaces the Buildroot tree and silently drops it, after which the build tries
to cross-compile LLVM and dies on disk. This is a trap with no error message
pointing at the cause. It wants either a `tools/` step or a CI assertion.

**The two carried kernel patches** (`pwrseq_simple` GPIO-reset fallback, sun4i
USB phy fix) are not upstream as of 6.18. Both need re-checking on any kernel
bump: without the first there is no WiFi, without the second no USB gadget.

## What "done" looks like

Every row in the table below has an answer that came from the device, not from
reading a config file:

| Item | Verified |
|---|---|
| Display, panel variant, GPU, GLES | yes |
| Gamepad buttons, LEDs, WiFi, USB gadget | yes |
| Battery, including charge/discharge | **yes** — flips both ways on the cable |
| Thermal, all four zones | **yes** — all rise under CPU load, CPU zone most |
| GPU does real work | **yes** — 4.74% fragment busy under kmscube, via fdinfo |
| RTC | **yes** — sane date, and it set the clock at boot |
| Volume buttons | **yes** — both directions register |
| Headphone jack detect | **yes** — plug detected |
| Audio codec bound | **yes** — card 0 present, mixer measured muted |
| Audio audible | no — needs a person, and needs arming |
| Bluetooth | **no — broken.** Fix built and present in the rootfs, not yet flashed |
| Power-off | route (2) implemented, never pressed |
| GPU frequency scaling | none — devfreq is empty |
| Thermal throttling | none — no cooling devices bound |
| HDMI | unknown, possibly not wired |

## Putting the rest on the panel

Everything still unverified has the same blocker: it needs someone holding
the device. Written as instructions, each one is a session over SSH with a
second machine. So they were moved onto the screen instead —
`ScenicRg40xxv.Diagnostics` collects the readings and
`ScenicRg40xxv.Scene.Diagnostics` draws them, reachable with **Y**.

Rows are coloured by meaning rather than by value: green proves a thing
works, red proves it does not, and amber means *nobody has done the physical
half yet*. Amber is the one that matters. Every failure in the table at the
top of this document was a case of "not tested" being read as "fine", and a
screen that only had green and red would reproduce that exact mistake.

The rows waiting on a person are marked with a bullet:

    • pull cable      battery status must flip to Discharging
    • press both      volume up and down counters must each move
    • plug/unplug     the jack switch must change
    • press A         run kmscube, and watch GPU utilisation, not heat

All four have now been done, and all four passed. The screen keeps them
because they are the checks to repeat after any kernel or device-tree
change, and because a row that has never been exercised should look
different from one that has.

Reached with **X**, not Y. The device tree disagrees, the shell is right.

Bluetooth shows `hci0`, `address` and the config blob as three separate rows,
because the first is exactly the check that lied.

Audio is shown and not played. The mixer state is on screen; the test is
built, armed by `config :scenic_rg40xxv, audio_test: false`, and bound to
**X** once that is `true`. It unmutes and plays in one step, so the result is
interpretable the first time.
