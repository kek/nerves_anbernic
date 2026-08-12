# Spec: the DE33 top block, decoded from the vendor BSP

**Date:** 2026-08-13
**Status:** Reference. Source review only — **nothing here was measured on
hardware this session**, and the device was not touched.
**Answers:** the question left as the top lead by the display work — what the
bits of `0x1008104` mean, given that a working muOS reads `0x111` there and this
tree reads `0x100`.

## Where this comes from

`orangepi-xunlong/linux-orangepi`, branch **`orange-pi-4.9-sun50iw9`**, path
`drivers/video/fbdev/sunxi/disp2/disp/de/lowlevel_v33x/de330/`. That is
Allwinner's own BSP for **sun50iw9** — the same SoC family as the H700, and the
same 4.9 kernel line muOS runs (`model = "sun50iw9"`, kernel 4.9.170). So it is
the register documentation for the exact silicon the comparison was made
against, which is why it settles naming questions that reading mainline cannot.

The MustardOS org has no kernel repo, so this is *not* muOS's own source. It is
the vendor BSP for the same SoC, which is the next best thing and is
self-consistent with every value muOS was measured to hold.

Relevant files: `de_top.c`, `de_top.h`, `de_rtmx.c`, `disp_al_de.c`. The 5.15
`sun55iw3` BSP was also checked; its `de_top.c` is materially identical.

## The register map

`de_base` is the DE33 bus, `0x1000000` on this board. Absolute addresses are for
this board.

| Offset | Absolute | BSP name | Meaning |
|---|---|---|---|
| `0x8000` | `0x1008000` | `ahb_reset_adr` | AHB reset, one bit per block: CORE0–3 = bits 0–3, WB = bit 4 |
| `0x8004` | `0x1008004` | `mod_en_adr` | Module clock enable, same bit positions |
| `0x8008` | `0x1008008` | `DE_MBUS_CLOCK_ADDR` | **DE MBUS clock enable** (bit 0) |
| `0x8010` | `0x1008010` | `DE2TCON_MUX_OFFSET` | **DE→TCON mux**, 2 bits per disp |
| `0x8014` | `0x1008014` | `DE_VER_CTL_OFFSET` | IP version |
| `0x8020` | `0x1008020` | `DE_RTWB_MUX_OFFSET` | Real-time writeback mux |
| `0x8024` | `0x1008024` | `DE_CHN2CORE_MUX_OFFSET` | Channel→core mux — mainline's `CHN2CORE` |
| `0x8028 + disp*4` | `0x1008028` | `DE_PORT2CHN_MUX_OFFSET` | Port→channel mux, 4 bits per port — mainline's `PORT02CHN` |
| `0x80E0` | `0x10080E0` | `DE_DEBUG_CTL_OFFSET` | Debug/LUT control |
| `0x8100 + disp*0x40` | `0x1008100` | `RTMX_GLB_CTL` | Real-time mixer global control |
| `0x8104 + disp*0x40` | `0x1008104` | `RTMX_GLB_STS` | Real-time mixer global **status** |
| `0x8108 + disp*0x40` | `0x1008108` | `RTMX_OUT_SIZE` | `(h-1)<<16 \| (w-1)` |
| `0x810C + disp*0x40` | `0x100810C` | `RTMX_AUTO_CLK` | Auto clock gating |
| `0x8110 + disp*0x40` | `0x1008110` | `RTMX_RCQ_CTL` | RCQ update trigger; `+4`/`+8` head address lo/hi, `+0xC` length |

Note the `disp * 0x40` stride: everything from `0x8100` is **per display
pipeline**, not global to the DE.

## `0x1008100` GLB_CTL — and what patch 0104 actually set

From `de_top_set_rtmx_enable()` and `de_top_enable_irq()` with the
`de_irq_flag` enum:

| Bit | Meaning |
|---|---|
| 0 | Real-time mixer enable (mainline's `SUN8I_MIXER_GLOBAL_CTL_RT_EN`) |
| 4 | Frame-end interrupt **enable** |
| 6 | RCQ-finish interrupt **enable** |
| 7 | RCQ-accept interrupt **enable** |

So the vendor's `0x41` is `RT_EN | RCQ_FINISH_IRQ_EN`, and
**`patches/linux/0104`'s "unknown" bit 6 is an interrupt enable** for the
register-configuration-queue mechanism — which this tree does not use at all.

That is worth stating plainly: **0104 cannot affect scanout**, which explains
why it changed nothing, and "the vendor sets this bit" is *not* evidence of a
missing enable. It is evidence that the vendor drives the DE in RCQ mode. The
patch is harmless (the interrupt it enables can never fire here) and matching
the vendor costs nothing, so it can stay — but its header should be rewritten to
say what the bit is, and it should not be treated as an open lead. Its "meaning
is unknown" claim is now false.

## `0x1008104` GLB_STS — the answer to the top lead

From `de_top_query_state_with_clear()` and the `de_irq_state` enum. All
write-1-to-clear:

| Bit | Meaning |
|---|---|
| 0 | **Frame end** |
| 2 | RCQ finished |
| 3 | RCQ accepted |

Measured previously: vendor `0x111`, ours `0x100`. The two differing bits are 0
and 4.

- **Bit 0 is the frame-end latch.** The vendor has completed frames. This tree
  never has. That is the sharpest single fact available about the fault, and it
  is consistent with everything else: correct timings, correct blender, correct
  pixel clock, and a display engine that has never finished a frame.
- **Bit 4 is not named** by either the 4.9 or the 5.15 BSP, and neither is bit 8
  (which both sides set). Do not guess at them; bit 0 is enough to work with.

**This gives an on-device progress oracle.** Any change that makes bit 0 start
latching has moved the DE from "never completes a frame" to "completes frames",
and that is one register read rather than a judgement about the colour of a
screen. Use it as the pass/fail signal for the next attempts instead of looking
at the panel.

## Two registers mainline never writes

Both are in the `0x1008000` window, which mainline's mixer cannot reach — its
DE33 `top` regmap starts at `0x8100`. The DE33 **clock** driver owns that window
and writes only `0x24` and `0x28`.

### `0x1008008`, the DE MBUS clock — checked, and probably fine by accident

`de_top_set_clk_enable()` enables the MBUS clock, reference-counted, whenever
*any* DE clock is enabled. MBUS is the DE's path to DRAM, so this looked like an
excellent candidate: without it the DE would clock out correct timings and fetch
no pixels, which is exactly the symptom.

It is probably already set, for an accidental reason worth writing down. The
DE2 and DE33 layouts of this window disagree:

| Offset | Mainline (DE2 tables) | Vendor (DE33) |
|---|---|---|
| `0x00` | Module clock gate | AHB reset |
| `0x04` | Bus clock gate | Module enable |
| `0x08` | AHB reset | **MBUS clock** |
| `0x0c` | Divider (M) | not used by `de_top.c` |

`sun50i_h616_de33_clk_desc` reuses `sun8i_h3_de2_hw_clks` and
`sun50i_h5_de2_resets` unchanged, so bringing up mixer0 sets bit 0 of `0x00`,
`0x04` *and* `0x08` — which under the vendor's layout is reset-deassert, module
enable and MBUS clock. All three land at `1` regardless of which mapping is
right, because mixer0 is bit 0 in both. Still worth one confirming read, since
it is free and the reasoning above is inference.

### `0x1008010`, the DE→TCON mux — never read on either side

Two bits per display pipeline selecting which TCON the DE feeds. Mainline never
writes it, so it sits at its reset value; muOS routes via `TCON_TOP_PORT_SEL`
(`0x651001c`, measured `0x20`), so this may simply be unused on H616. But it is
a routing register in the data path that has never been read on *either* side,
which makes it the cheapest unexamined thing left.

## The channel layout, exactly — and a retired data point

From `de_top.h`:

```
DE_CHN_OFFSET(phy_chn) = 0x100000 + 0x20000 * phy_chn
CHN_OVL_OFFSET         = 0x1000
DE_DISP_OFFSET(disp)   = 0x280000 + 0x20000 * disp
DISP_BLD_OFFSET        = 0x1000
```

`de_top_set_uchn2core_mux()` computes its shift as `((phy_chn - 6) << 1) + 16`,
i.e. **UI channels are physical channels 6, 7, 8**. That matches mainline's
`sun50i_h616_mixer0_cfg` exactly — `.map = {0, 6, 7, 8}` with `vi_num = 1` and
`ui_num = 3` — an independent confirmation that mainline's channel map is right.

Overlay blocks for this board:

| Channel | Absolute |
|---|---|
| VI 0 (physical 0) | `0x1101000` |
| **UI 0 (physical 6)** | **`0x11C1000`** |
| UI 1 (physical 7) | `0x11E1000` |
| UI 2 (physical 8) | `0x1201000` — **avoid**, adjacent to the region that hung the SoC |

**This retires a data point that was being treated as suspicious.** muOS reading
`0x00000000` at `0x1101000` is exactly what should be expected: that is the
*video* channel, and neither the vendor's console nor our fbcon uses it. The
plane both sides actually scan out is a **UI** channel, at `0x11C1000`. It was
never evidence that the `layers` base was wrong.

## The double-buffer dead end, explained

The previous session established empirically that `0x1008104` is not a
double-buffer register, after trying to use it as one. The BSP says why, and
confirms mainline is right to skip it:

- DE33's real commit trigger is `RTMX_RCQ_CTL` at `0x8110` — inside mainline's
  `top` regmap window (offset `0x10`, below its `max_register` of `0x3c`), but
  only meaningful in RCQ mode, where register blocks are DMA'd from a queue in
  DRAM.
- In non-RCQ mode the vendor does not latch anything. `de_rtmx_update_reg_ahb()`
  simply `memcpy`s each dirty shadow block straight into MMIO.

So mainline's `if (de_type != SUN8I_MIXER_DE33)` guard around `GLOBAL_DBUFF` is
architecturally correct rather than an oversight, and direct register writes are
a legitimate way to drive this hardware. **That is one fewer explanation for the
symptom**, not a new lead.

## What to measure next, in order

One `devmem <addr> 32` each on muOS with the screen lit, against regmap debugfs
(or busybox `devmem`, still worth adding) on this image. All are single reads in
windows already known to respond.

1. **`0x1008010`** — the DE→TCON mux. Never read on either side.
2. **`0x11C1000`** and the words after it — the UI channel-0 overlay block, on
   both sides. Look for a plausible framebuffer address (`0x4xxxxxxx`). This is
   the first point where "does the DE have the pixels" becomes directly
   checkable, and the previous session was guessing at the base; it is now
   derived.
3. **`0x1008008`** — the MBUS clock, to confirm the accident above.
4. **`0x1008104` bit 0** on this image after any change — the progress oracle.

> The standing warning still applies: reading DE33 addresses speculatively
> **hangs the SoC**. Read one address at a time, only in windows known to
> respond, and stay away from `0x1200000`.

## What this does not do

It does not explain why the display engine never completes a frame. It renames
one patch's justification, removes two candidate explanations (the plane
mapping's magic constants were already dead; the DBUFF theory is now dead by
construction as well as by measurement), replaces a guessed register base with a
derived one, and turns "the screen is green" into a one-read boolean. The
ROCKNIX planes refactor remains the fallback, and the note against it stands:
its stated motivation was measured not to apply here.
