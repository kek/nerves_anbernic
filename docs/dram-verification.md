# DRAM type, verified on hardware

**Result: this unit's DRAM is LPDDR3.** Established 2026-08-21 by a
differential FEL experiment on the device itself — not by spec sheets,
not by this repo's own earlier prose.

## Why it needed verifying at all

The "1 GB LPDDR4" claim circulates in reviews and in the ROCKNIX wiki
(whose RG40XX V hardware table reads "RAM: 1 GB LPDDR4" — verified
directly). Anbernic's own product pages, checked directly for both the
RG40XX V and RG40XX H, say only "RAM: 1GB" with no type at all — the
LPDDR4 attribution is secondhand everywhere it appears. Meanwhile this
repo's
`uboot/uboot.defconfig` selects `CONFIG_SUNXI_DRAM_H616_LPDDR3`, justified
only by documentation written during bring-up ([bring-up.md](bring-up.md)
§1). Nothing committed here was primary evidence: no boot0 dump, no boot
log, no chip photo. A claim and its citation shared an author.

Two external facts reframe the question:

- **ROCKNIX ships two U-Boot builds for H700** — `u-boot-DDR3` and
  `u-boot-DDR4` — and picks between them *per unit* at runtime by reading
  the `vdd-dram` regulator (1.2 V → LPDDR3 build, 1.1 V → LPDDR4 build) in
  `projects/ROCKNIX/devices/H700/bootloader/update.sh`. They have per-model
  device-tree IDs in hand in that same script and still chose a measured
  electrical property to select the bootloader — so model identity is not
  a reliable predictor of DRAM type across the H700 line. Whether two
  RG40XXV units specifically have shipped with different types is
  unobserved by us; what is certain is that both types exist across the
  H700 family, and that this unit is LPDDR3 despite the LPDDR4 label the
  model carries in community documentation. "The H700 family is uniformly
  LPDDR4" is simply wrong.
- **Allwinner's H700 product brief** lists the memory interface as
  "DDR4/DDR3/DDR3L/LPDDR3/LPDDR4" — both types are first-class options for
  H700 designs, so nothing about the SoC settles it.

Their LPDDR3 defconfig
(`anbernic_rg35xx_h700_lpddr3_defconfig`) matches ours nearly byte-for-byte
(same `TPR10=0x402f4489`, ODT, drive strengths, 672 MHz; TPR11 differs in
two bytes), independently corroborating that our parameter set is the
community-validated LPDDR3 set rather than a bring-up invention.

## The experiment

An A-B-A differential test over FEL (Allwinner's USB recovery protocol):
load an SPL built for each DRAM type directly into SRAM, let it attempt
DRAM training, and check whether a 1 MiB random pattern written to
`0x40000000` reads back intact. Nothing persistent is touched. The wrong
type hangs H616-class training — that hang is the whole reason ROCKNIX
needs two builds — so the *pair* of outcomes is a clean oracle on the chip.

Binaries used (kit staged in `~/src/rg40xxv-fel-test/`):

- `spl-ours.bin` — this system's 0.2.0 `u-boot-sunxi-with-spl.bin`.
- `spl-rocknix-DDR4.bin`, `spl-rocknix-DDR3.bin` — cut from the 8 KiB
  offset of ROCKNIX release `20260801`'s DDR4/DDR3 images.

Each binary was fingerprinted by its compiled-in TPR10 immediate before
use: ours and ROCKNIX-DDR3 contain `0x402f4489` (LPDDR3 set),
ROCKNIX-DDR4 contains `0x402f6633` (upstream's LPDDR4 set). So each SPL
verifiably *is* what its name claims, independent of anyone's docs.

FEL entry on this device: remove both SD cards, USB-C into the OTG port,
power on — the BROM finds no eGON image and drops into FEL. The probe
reports `soc=00001823(H616)`: the H700 is H616 silicon to the BROM.

## Transcript (2026-08-21, sunxi-fel on macOS)

```
$ ./fel-dram-test.sh probe
AWUSBFEX soc=00001823(H616) 00000001 ver=0001 44 08 scratchpad=00027e00 ...

$ ./fel-dram-test.sh lpddr3
== Loading spl-ours.bin via FEL (a hang here means DRAM training failed) ==
== SPL returned. Testing DRAM readback at 0x40000000 ==
RESULT: DRAM trained and 1 MiB pattern read back intact with spl-ours.bin.

$ ./fel-dram-test.sh lpddr4
== Loading spl-rocknix-DDR4.bin via FEL (a hang here means DRAM training failed) ==
usb_bulk_send() ERROR -1: Input/Output Error
RESULT: SPL did not return to FEL — DRAM init hung with spl-rocknix-DDR4.bin.

$ ./fel-dram-test.sh lpddr3
== Loading spl-ours.bin via FEL (a hang here means DRAM training failed) ==
== SPL returned. Testing DRAM readback at 0x40000000 ==
RESULT: DRAM trained and 1 MiB pattern read back intact with spl-ours.bin.
```

LPDDR3 trains and verifies, twice, bracketing an LPDDR4 hang on the same
hardware and cable. The chip is LPDDR3.

## Open question: vdd-dram is 100 mV under the community value

Our SPL sets `CONFIG_AXP_DCDC3_VOLT=1100` and the inherited upstream DTS
(`sun50i-h700-anbernic-rg35xx-2024.dts`) pins the `vdd-dram` regulator
always-on at 1.1 V — the LPDDR4 voltage. ROCKNIX's LPDDR3 build uses
**1200**, matching LPDDR3's nominal 1.2 V VDD2. This unit demonstrably
trains and runs at 1.1 V, but the stability margin is unquantified.
Follow-up: try `CONFIG_AXP_DCDC3_VOLT=1200` plus a DTS override of the
dcdc3 constraint, and soak-test (memtester) at both voltages before
changing anything. Note this pinning also blinds ROCKNIX's voltage-based
detection trick on our image: sysfs will read 1.1 V regardless of chip.

A wording nit deferred on purpose: the comment in `uboot/uboot.defconfig`
still says "The RG40XXV has LPDDR3", which overstates (it should say "this
unit"). Any edit under `uboot/` invalidates the artifact checksum and costs
a full rebuild, so the correction should ride along with the next real
`uboot/` change — most likely the DCDC3 voltage experiment above.

## If this ever needs re-verifying

Re-run the kit (`~/src/rg40xxv-fel-test/fel-dram-test.sh`, or rebuild it:
sunxi-tools plus any LPDDR3/LPDDR4 SPL pair with verified TPR10
fingerprints). Definitive alternatives: photograph the DRAM package
marking and decode the part number, or dump the vendor boot0 from a stock
or muOS card (`dd bs=512 skip=16 count=256`) and read `dram_para` offset
`0x38`: 7 = LPDDR3, 8 = LPDDR4.
