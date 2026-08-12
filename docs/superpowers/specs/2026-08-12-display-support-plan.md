# Plan: display support for the RG40XXV

**Date:** 2026-08-12
**Status:** All three prerequisites done. Implementation not started.
**Prerequisite:** met — the board boots, joins WiFi and is reachable over SSH
as of `e15351a`. This plan assumes that; it would not be workable without it.
**Expands:** the "Adding display support" section of the README, which states
*what* to add. This states *how* to work on it.

## Why this needs a plan rather than just patches

The 4" panel needs an out-of-tree stack — the H616 PWM controller driver,
`panel-mipi-dpi-spi`, and a sun4i RGB-connector change, roughly 23 patches as
carried by ROCKNIX. None of that is the hard part.

The hard part is that **"no picture" covers at least four unrelated failures**:
the DRM driver never bound, it bound but no connector was detected, a connector
and mode exist but the panel init sequence is wrong, or everything is right and
the backlight is off. They are indistinguishable by looking at the device, and
this board offers no other feedback — the screen is the thing under test, so it
cannot report on itself.

Compounding it: the RG40XXV shipped with **two different panels**, and the
wrong one gives a blank or scrambled screen. That is why ROCKNIX carries
`sun50i-h700-anbernic-rg40xx-v-v2-panel.dts` alongside the base DTS. Guessing
which one this unit has is expensive, because a wrong guess is
indistinguishable from a bug in the code.

So the plan is mostly about making each step produce a *distinct, readable*
signal before writing the step.

## The loop

Faster than the loop used for the DRAM and WiFi work, because of one fact worth
stating explicitly:

**Kernel and device-tree changes ship over `mix upload`.** `/boot/Image` and the
DTB live inside the rootfs squashfs, and the `upgrade.a`/`upgrade.b` fwup tasks
rewrite that partition. Only the bootloader is excluded from A/B updates. So
there is no card swapping in this loop — roughly 1–2 minutes per iteration.

```
edit patch or DTS
  → make linux-rebuild        in the persistent Docker volume (minutes)
  → repackage artifact, mix firmware
  → mix upload                (~1-2 min, no card removal)
  → ssh in, read dmesg + /sys/class/drm + modetest
```

The Buildroot build volume persists between runs, so only what changed is
rebuilt:

```bash
docker run --rm --name nerves-rebuild --log-driver none \
  --mount type=volume,src=nerves_system_rg40xxv-<id>,target=/home/nerves/project \
  --mount type=bind,src=$PWD/deps/nerves_system_br,target=/nerves/env/platform \
  --mount type=bind,src=$PWD,target=/nerves/env/nerves_system_rg40xxv \
  --mount type=bind,src=$HOME/.nerves/dl,target=/nerves/dl \
  --env NERVES_BR_DL_DIR=/nerves/dl \
  --env NERVES_DEFCONFIG_DIR=/nerves/env/nerves_system_rg40xxv \
  -w /home/nerves/project ghcr.io/nerves-project/nerves_system_br:1.34.1 \
  bash -c 'make linux-rebuild </dev/null 2>&1 | tail -40'
```

`--log-driver none` and `</dev/null` are not optional. A Kconfig prompt with no
tty loops on EOF forever and will fill the Docker VM disk through the container
log; that happened once already.

## Prerequisites, before writing any display code

### 1. Add libdrm with its test tools — DONE

There was no way to inspect DRM state on-device. Adding the display
stack without this repeats the mistake of shipping a button-test procedure on
an image with no `evtest`.

```
BR2_PACKAGE_LIBDRM=y
BR2_PACKAGE_LIBDRM_INSTALL_TESTS=y
```

Now in `nerves_defconfig`, and the image carries `modetest`, `proptest` and
`modeprint` in `/usr/bin`. `modetest` enumerates connectors, CRTCs and modes and
can draw a test pattern — the cheap way to tell "DRM never bound" from "bound
but dark". No per-GPU option is set: those build vendor userspace libraries,
while `modetest` uses the generic KMS ioctls.

Still optional: `fbset`, and `kmscube` once panfrost matters.

### 2. Turn on revert protection — DONE

`uboot/uboot.env` used to set `nerves_fw_autovalidate=1`, which made the A/B
revert machinery a no-op: `nerves_init` marked new firmware valid on its first
boot whether or not the system came up, so a kernel that failed to boot left
the device recoverable only by re-flashing.

It is now `0`. The rest of the chain was already in place — the fwup upgrade
tasks set `nerves_fw_validated=0` when they apply an update, and `nerves_init`
reverts on `booted=1` with `validated=0`.

**Something must do the validating.** `nerves_runtime`'s `StartupGuard` does,
and only once every OTP application has started, so enable it in the
application:

```elixir
config :nerves_runtime, startup_guard_enabled: true
```

Without that (or a direct `Nerves.Runtime.validate_firmware/0` call) the device
reverts on every second boot. handheldgame already sets it.

> [!IMPORTANT]
> **This takes one `mix burn` to install.** The environment reaches a device
> only through fwup's `complete` task, so a `mix upload` will not carry it. Do
> that burn *before* starting display work — the whole point is to make the
> kernel uploads that follow recoverable.
>
> Two traps found while making this change. Buildroot depends on the *path* of
> `uboot/uboot.env` but not its contents, so editing it does not regenerate
> `images/uboot-env.bin`; force it with `make host-uboot-tools-rebuild && make`
> and verify with `strings images/uboot-env.bin | grep nerves_fw_`. It is
> commented at the `ENVIMAGE_SOURCE` line in `nerves_defconfig`.

### 3. Get the panel spec — DONE, by a better route

The plan here was to decompile muOS's DTB. That turned out to be unnecessary and
would have been misleading: ROCKNIX carries the whole stack as committed source,
and reading it revealed two things a DTB would not have shown.

Recorded in `2026-08-12-display-panel-spec.md`. The two findings that change the
work:

- **The panel description is a firmware blob**, `/lib/firmware/panels/<compatible>.panel`,
  carrying the timings *and* the init sequence. There is no `panel-timing` node
  anywhere. Kernel patches plus device tree, without those files in the rootfs,
  gives no picture and no obvious error.
- **Both variants are 640x480 @ 60 Hz with identical blanking.** They differ in
  init sequence, sync polarity (inverted) and pixel-clock edge. So `modetest`
  reporting the right mode does **not** confirm the right panel, and a scrambled
  image means wrong *variant* rather than wrong timings.

Only 7 of ROCKNIX's 23 H700 patches are display-related, so this is a smaller
job than the README's "roughly 23 patches" suggests.

## Step sequence

Add nodes in this order, because each step has a different observable and
skipping ahead makes failures ambiguous.

| Step | Add | Success looks like |
|---|---|---|
| 1 | Patch series only, no DT nodes | Kernel still boots; drivers present via `modinfo`. No regression |
| 2 | TCON + DE2 / mixer nodes | `/sys/class/drm/card0` exists; `modetest` lists a CRTC. **Screen still black — this is progress** |
| 3 | `.panel` blobs into `/lib/firmware/panels/` | Nothing visible yet, but step 4 cannot work without them |
| 4 | `spi_lcd` + `reg_lcd` + panel node | Connector `connected`, mode 640x480 @ 60 Hz. **Does not prove the variant is right** |
| 5 | Backlight (H616 PWM, PD28) | Actual light |

Do step 1 as its own upload and confirm no regression before adding any nodes.
A display patch series that breaks something unrelated is much easier to spot
against a known-good boot than tangled with new DT.

**The diagnostic split that matters most** is between steps 4 and 5, because
they are the two most often conflated. Read it with the panel spec in hand:

- no connector at all → the panel node is not binding; step 4 is not done
- correct mode, screen black → backlight (step 5), or the `.panel` blob is
  missing so no init sequence ran
- correct mode, scrambled or rolling image → **wrong panel variant**, not wrong
  timings. Both variants report 640x480 @ 60 Hz; they differ in sync polarity
  and init sequence. Switch the `compatible` to the other one, which is a
  one-line change and a single upload.

Since the mode looks identical either way, resist reading a correct mode as
confirmation of anything beyond "the pipeline is configured".

## Patch hygiene

`patches/linux/` is already wired through `BR2_GLOBAL_PATCH_DIR`, and `patches`
is in `package_files()` so editing a patch correctly invalidates the artifact.
That matters immediately here: without it, a tweaked display patch would
silently rebuild the old kernel.

- One patch per concern, numbered for stable ordering: PWM driver, panel
  driver, sun4i RGB connector, then DT last.
- Header comment per patch recording upstream status. `panel-mipi-dpi-spi` is
  in-flight upstream, so plan on **dropping** it rather than carrying it.
- Put the series under `linux/display/` or a numbered range in
  `patches/linux/` so it can be reasoned about as a unit.

**Iteration technique, with the caveat that bit once already.** For speed,
hand-apply changes into the volume's extracted kernel tree and use
`make linux-rebuild`; formalise into a patch file once a change settles. This
works well — it is how the `pwrseq_simple` fix was developed — but the
hand-applied tree and the committed patch drift apart, and a defconfig change
was very nearly shipped that existed only inside the volume. **Before believing
a result, run `make linux-dirclean` and rebuild** so patches and defconfig are
re-derived from committed files.

## Making both panels selectable

The DTB is referenced explicitly by filename from the rootfs:

```
fdt /boot/sun50i-h700-anbernic-rg40xx-v.dtb
```

so a second variant needs either its own `extlinux` entry pointing at a second
DTB, or a U-Boot device tree overlay. `uboot/uboot.env` already defines
`fdtoverlay_addr_r`, so the overlay route is available without U-Boot config
changes. Ship both variants regardless of which one this unit needs — the other
is unusable on the wrong hardware, and a blank screen is not a good way to
discover that.

## Definition of done

- `modetest` reports a connected connector with the panel's native mode
- A test pattern is visible, with correct geometry and colour
- Backlight is controllable through `/sys/class/backlight`
- Both panel variants exist and are selectable
- A clean `linux-dirclean` rebuild from committed sources reproduces it
- The README's "display does not work, on purpose" section is rewritten, and
  the `Display` row of its hardware table stops saying "Not supported"

## Notes

- **Keep the muOS card.** It is both the panel spec and the control experiment.
- **Do not chase `panfrost 1800000.gpu: probe ... failed with error -110` yet.**
  That is a deferred-probe timeout in the current headless build and may clear
  itself once TCON/DE2 exist. Revisit after step 2.
- `CONFIG_DRM_SUN4I=m` is already enabled, as are a number of
  `CONFIG_DRM_PANEL_*` drivers; check what is already there before adding to
  `linux/nerves.fragment`.
- Display work does not need `BootDiagnostics` or the verbose-boot extlinux
  overrides from the bring-up sessions. Failures here leave SSH alive, so
  `dmesg` covers it; the case that loses SSH is a kernel panic, and the answer
  to that is A/B revert, not a diagnostic that needs the application running.
