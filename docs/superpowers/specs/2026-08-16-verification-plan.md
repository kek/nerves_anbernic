# Plan: verifying what was inherited but never tested

**Date:** 2026-08-16
**Status:** Plan. Nothing here has been run yet.

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
| Battery, thermal, RTC, Bluetooth | no |
| Audio | no |
| Volume buttons | no |
| Power-off | known gap |
| HDMI | unknown, possibly not wired |
