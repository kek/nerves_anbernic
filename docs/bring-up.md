# What bring-up actually found

Five things, none of which were visible from source review. The display was a
sixth and has [its own document](display.md).

## 1. The board is LPDDR3, not LPDDR4

This is the important one, and it is now settled from two directions rather
than inferred from one: the vendor's own bootloader declares LPDDR3, and the
DRAM controller in the running device is driving it. `tools/dram-type.sh` is
both checks. `configs/anbernic_rg35xx_h700_defconfig` upstream
specifies `CONFIG_SUNXI_DRAM_H616_LPDDR4`, and this system copied it verbatim
on the premise that the H700 Anbernics share a PCB family. They do not share
memory. With LPDDR4 timings the SPL hangs in DRAM init and the SoC stops
responding entirely — no console, no LED, indistinguishable from a dead device.

The correct values came from the **vendor boot0 on a muOS card** that boots
this hardware. Its `dram_para` struct at offset `0x38` declares
`dram_type = 7` (LPDDR3) and carries different drive-strength and ODT values,
while agreeing with upstream on the 672 MHz clock — which is what confirmed
the struct offset had been read correctly:

```bash
sudo dd if=/dev/rdiskN bs=512 skip=16 count=256 of=boot0.bin
tools/dram-type.sh boot0 boot0.bin
```

`tools/dram-type.sh` is the mechanical form of that reading, added later to
settle the question rather than assert it. It does four things the original
hand-decode did not:

- **Verifies the eGON checksum.** A 32-bit sum over the header's declared
  length, with the checksum field replaced by Allwinner's stamp value. It
  passes on this blob, which proves both that the image is intact and that the
  header layout is the documented one — the arithmetic cannot come out right
  unless the checksum is at `0x0c` and the length at `0x10`.
- **Cross-checks five consecutive fields** against `uboot/uboot.defconfig`.
  The clock, ODT and both drive-strength words all agree, which is the struct
  offset confirmed rather than assumed.
- **Reads the mode registers**, which are the strongest signal in the blob and
  were not looked at the first time. boot0 carries `MR1/MR2/MR3 =
  0x83/0x1c/0x01`, byte-identical to the sequence u-boot's `mctl_phy_init()`
  writes on its `SUNXI_DRAM_TYPE_LPDDR3` arm — where the comment reads
  *"MR1: nWR=14, BL8"*. LPDDR4 is BL16 and its arm writes `0x0, 0x134, …`,
  nothing alike. These are values the vendor programs into the die itself.
- **Refuses to decode** a blob whose magic or checksum is wrong, rather than
  reporting a plausible type from garbage. `tools/dram-type.sh selftest`
  checks that, against synthesised images, in CI.

`dram_type = 7` is `SUNXI_DRAM_TYPE_LPDDR3` per the enum in
`arch/arm/include/asm/arch-sunxi/dram_sun50i_h616.h`, where `DDR3 = 3` and
`DDR4 = 4` — so the non-LP variants are excluded by the same number.

The other half of the question is what the silicon is actually driving, which
no file can answer. `MSTR`, at `SUNXI_DRAM_CTL0_BASE` = `0x047FB000` on the
H616, holds the device type in bits `[5:0]` and the burst length in `[19:16]`;
u-boot writes both from the same switch arm, so they corroborate each other.

```
tools/dram-type.sh device            # reads it over ssh and decodes
tools/dram-type.sh mstr 0xc1040008   # or decode a word you read yourself
```

Measured on the device: **`MSTR = 0xc1040008`** — device type `0x08`
(`MSTR_DEVICETYPE_LPDDR3`), burst length 8, full bus width, one rank.

That number is worth more than a matching name, because it was derived from
u-boot's own expression before the hardware was read. `mctl_com_init()` writes
`BIT(31) | BIT(30) | MSTR_ACTIVE_RANKS(1) | MSTR_BURST_LENGTH(8) |
MSTR_DEVICETYPE_LPDDR3`, which is `0xc0000000 | 0x01000000 | 0x00040000 | 0x8`
= `0xc1040008`. The prediction is in the tool's self-test; the silicon returned
it bit for bit. LPDDR4 would have read `0xc1080020`.

So the controller in this device is driving LPDDR3, and the device serves reads
out of that DRAM — which settles the die too. The two protocols are mutually
unintelligible at the command level: a controller configured for LPDDR3 cannot
train, let alone serve traffic, against an LPDDR4 device.

Worth knowing before running `device`: a stray MMIO read has hung this SoC
before. The DRAM controller is a live, documented window and this is a read, so
the risk is low and the worst case is a power cycle — but it is not zero. It
did not hang when this was measured.

### The negative control

Two positive measurements still leave a loophole: perhaps the setting is inert.
The claim that the H700 family is uniformly 1 GB LPDDR4 circulates widely, and
the reconciliation offered for it is that DRAM init happens in a vendor blob and
the Kconfig symbol is never consulted — in which case LPDDR3 and LPDDR4 would
both appear to work.

That label is secondhand wherever it appears. Anbernic's own product page for
the RG 40XXV states `RAM: 1GB` and names no type at all; the LPDDR4 attribution
comes from reviews and the ROCKNIX wiki. And ROCKNIX ships *two* H700 U-Boot
builds, selecting between them per unit by reading the `vdd-dram` regulator
rather than by model — having per-model device-tree IDs to hand and choosing a
measured electrical property instead. So model identity does not predict the
memory type across this family, and what follows is a fact about **this unit**
rather than about the model. `docs/dram-verification.md` carries that sourcing.

That is checkable twice over, and both checks close it.

**There is no vendor blob in this boot chain.** `fwup.conf` writes
`u-boot-sunxi-with-spl.bin` at `UBOOT_OFFSET`, block 16 — byte 8192, exactly
where a vendor boot0 lives, so ours replaces it. Read back from the device, the
64 KiB at byte 8192 hashes identical to this repository's own built image for
the firmware version the device reports, and its eGON header declares 40960
bytes: a mainline sunxi SPL, not the vendor's 65536.

**And the symbol is load-bearing.** `tools/dram-falsify.sh` builds four SPLs
from one U-Boot tree differing only in DRAM configuration and runs each over
FEL. Run on 2026-08-21, with the outcomes written down beforehand:

| variant | configuration | result |
|---|---|---|
| `lpddr3` | ours | **DRAM up**, `0x40000000` and `0x40100000` independent |
| `lpddr4-upstream` | upstream's whole LPDDR4 block, verbatim | SPL hung in DRAM init |
| `lpddr4-typeonly` | type swapped, every analog value unchanged | SPL hung in DRAM init |
| `ddr3-typeonly` | same, DDR3-1333 | SPL hung in DRAM init |

The two type-only rows are the tight ones. They change nothing but the
protocol — same 672 MHz clock, same ODT, same drive strengths, same TPR words —
and they turn a working DRAM init into a hang. A value that is never consulted
cannot do that.

`lpddr4-upstream` is the direct answer to the LPDDR4 claim: it is the
configuration upstream ships for the H700 Anbernic usually called identical
hardware, at the same clock upstream pairs with it, and it does not train this
memory. Meanwhile LPDDR3 does, and serves two addresses 1 MB apart
independently. Since the two protocols are mutually unintelligible — different
CA width, different signalling, different mode-register map, so a PHY set up
for one cannot train the other at all — that settles the die and not merely the
configuration.

What none of this reads is the marking on the package. Given that ROCKNIX
selects per unit rather than per model, the honest scope is this unit: its
memory speaks LPDDR3, which is the question a BSP is asking. Another RG40XXV
could in principle differ, and the check to run on one is `tools/dram-type.sh`.

**Open, and more actionable than any of the above:** `CONFIG_AXP_DCDC3_VOLT`
is 1100, taken verbatim from upstream's *LPDDR4* defconfig along with the rest
of the PMIC block. ROCKNIX's LPDDR3 build uses 1200, and 1.1 V is the value
their script reads as meaning LPDDR4. So this may be LPDDR3 memory running at
the LPDDR4 core voltage — the same inherited-block mistake as the DRAM timings,
caught on one half and not the other. Undervolted DRAM does not hang; it
corrupts rarely, under load and heat. Confirm which rail DCDC3 drives on this
board before changing anything, and soak-test after.

If you ever doubt an inherited hardware parameter, that is the technique: a
firmware known to boot the hardware is ground truth in a way a sibling
board's defconfig is not. See the comment in `uboot/uboot.defconfig`, which
also records that the TPR field ordering is *inferred* rather than confirmed
against a struct definition — the one part of this the tool does not settle.

## 2. `pwrseq_simple` aborts instead of using its own GPIO fallback

On 6.18 it demands a reset controller whenever a node has exactly one
`reset-gpios` entry, and returns early when it cannot get one, skipping the
GPIO path directly below it. Our WiFi node has `reset-gpios` and no `resets`,
so mmc1 never initialised and `wlan0` never existed. Fixed by
`patches/linux/0001-mmc-pwrseq_simple-gpio-reset-fallback.patch`.

## 3. `CONFIG_IP_ADVANCED_ROUTER` and `CONFIG_IP_MULTIPLE_TABLES` were missing

vintage_net gives each interface its own routing table, so without them
`VintageNet.RouteManager` crashes moments after DHCP succeeds. The symptom is
WiFi that associates, obtains a lease, deauthenticates "by local choice", and
loops — present and configured but never reachable.

## 4. The LED is a charge indicator, not a boot signal

An earlier version of the documentation offered an LED-based triage tree on the
reasoning that `CONFIG_SPL_SUNXI_LED_STATUS_GPIO=268` (PI12) is the power LED,
so the SPL lights it before Linux. That reasoning is sound but the conclusion is
not: on real hardware the LED glows a steady yellow whenever the device has
power, because it is the AXP717's charge indicator, so it looks identical
whether the device booted or is wedged.

**Do not read anything into the LED at power-on.**

An application can create a real signal by pointing a LED at the kernel's
heartbeat trigger, which is worth doing — a blinking LED then means kernel up,
BEAM up, application supervision tree up:

```elixir
File.write("/sys/class/leds/green:status/trigger", "heartbeat")
```

`/sys/class/leds` has `green:power`, `green:status`, `rgb:indicator` and
`rtw88-mmc1:0001:1`. This needs no kernel changes; `CONFIG_LEDS_GPIO` and
`CONFIG_LEDS_TRIGGER_HEARTBEAT` are already built in.

## 5. The OTG phy is shared, and the host driver was winning it

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

# How this was verified

On-device boot **is** confirmed. What follows is the build-time verification
reached *before* any hardware was available. It is kept because CI still
enforces all of it on every change, and because the gap between it and reality
turned out to be the instructive part.

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
for survives `olddefconfig`, and the boot-critical driver list is asserted
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
of the things that actually stopped the board — a DRAM type, a driver's
early-return, two absent kernel symbols, the colour of a LED, and one missing
device tree property. Well-formed is not the same as correct, and the distance
between them is the size of the hardware you do not have.

The "matches its siblings" premise held for the PMIC, mmc0, the gamepad and
WiFi, and broke for DRAM. Of the inherited assumptions, the button GPIO mapping
is the one still unexercised.
