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

## The blender comparison was incomplete, and two registers were mislabelled

The round-two comparison concluded that "the blender is programmed identically
to a configuration that drives this panel". It read three registers at
`0x1281000`, `0x1281004` and `0x1281008`. Against both mainline's macros and the
vendor's `struct bld_reg`, only the first of those three is what it was called:

| Address | Called | Actually |
|---|---|---|
| `0x1281000` | `BLEND_PIPE_CTL` | correct — pipe enables (bits 8+) and fill-colour enables (bits 0+) |
| `0x1281004` | `BLEND_BKCOLOR` | **`BLEND_ATTR_FCOLOR(0)`** — pipe 0's *fill* colour |
| `0x1281008` | `BLEND_OUTSIZE` | **`BLEND_ATTR_INSIZE(0)`** — pipe 0's *input* size |

The real ones are further along, and **none of the three has ever been read on
either side**:

| Address | Register | Expected here |
|---|---|---|
| `0x1281080` | `BLEND_ROUTE` | `0x1` |
| `0x1281088` | `BLEND_BKCOLOR` | `0xFF000000` |
| `0x128108C` | `BLEND_OUTSIZE` | `0x01DF027F` |

One conclusion has to be withdrawn as a result. The claim that "the vendor's
background colour is **black**, so the uniform green is not a configured
background" was read off `0x1281004`, which is pipe 0's fill colour, not the
background. The background colour register at `0x1281088` is still unmeasured on
both sides, so that argument does not currently hold — it may well survive
re-measurement, but it has not been made yet.

`BLEND_ROUTE` is the interesting one of the three. Four bits per pipe select
which blender *port* feeds it, and mainline writes the **logical** channel index
(`route |= layer->channel << (zpos << 2)`). That looks like a candidate bug —
physical channels here are 0, 6, 7, 8 — but it is correct, and the vendor's own
constant proves it. `0xa980` at `0x1008028` is `PORT02CHN`, four bits per port:

| Port | Nibble | Channel |
|---|---|---|
| 0 | `0x0` | VI 0 (physical 0) |
| 1 | `0x8` | UI 0 (physical 6, written as `phy_chn + 2`) |
| 2 | `0x9` | UI 1 (physical 7) |
| 3 | `0xa` | UI 2 (physical 8) |

So port index and logical channel index coincide by construction, and routing a
pipe to "channel 1" reaches physical channel 6 through that mapping. Mainline's
magic constant and its route arithmetic agree with the vendor exactly.

## The rest of the register map is validated against the vendor

Everything below was checked offset by offset against the BSP structs, and
matches. Only the **top block** diverges between DE2 and DE33 — and there,
mainline's reuse of the DE2 clock tables happens to land on the right bits
because mixer0 is bit 0 under both layouts.

- **Blender.** `struct bld_reg` puts `rout_ctl` at `0x80`, `premul_ctl` `0x84`,
  `bg_color` `0x88`, `out_size` `0x8c`, colour key at `0xb0`/`0xb4`, `0xc0`,
  `0xe0`. Mainline's macros are identical. Its pipe-attribute stride of `0x10`
  matches `struct bld_pipe_attr`, and the `en` register overlaying `attr[0]`'s
  first word is why `PIPE_CTL` sits at offset 0.
- **Channel addressing.** `map[ch] * 0x20000 + 0x1000` is exactly the vendor's
  `DE_CHN_OFFSET(phy_chn) + CHN_OVL_OFFSET`.
- **UI layer registers.** `struct ovl_u_lay_reg` is ctl, size, coord, pitch,
  top_laddr, bot_laddr, fcolor over a `0x20` stride, then `top_haddr` `0x80`,
  `bot_haddr` `0x84`, `win_size` `0x88`. Mainline's `SUN8I_MIXER_CHAN_UI_*`
  macros match byte for byte.

The one difference worth noting is pipe count: DE33 has **six** blender pipes
(`pipe0_en`..`pipe5_en` at bits 8–13), while mainline's
`SUN8I_MIXER_BLEND_PIPE_CTL_EN_MSK` is `GENMASK(12, 8)` — five. Harmless with a
single plane on pipe 0, and worth remembering only if more planes are used.

## Which plane is actually being scanned out

`sun8i_ui_layer_init_one()` makes **UI index 0 the primary plane**, and its
channel is `vi_num + index` = **logical channel 1**, i.e. physical channel 6. So
fbcon's `XR24` buffer is a UI layer, not the video layer, and its registers are
at `0x11C1000`. The video channel at `0x1101000` is unused by both sides.

## What to measure next, in order

One read each on muOS with the screen lit, against the same read on this image.
All are single reads in windows already known to respond.

**Both sides now have `/sbin/devmem`.** It was missing here, which is what
stopped the previous session; `busybox/busybox.fragment` turns it back on, since
nerves-common's busybox config disables it. muOS has it at the same path, so the
same command runs on both:

```sh
devmem 0x11C1010 32
```

Over SSH this image answers with Elixir rather than a shell, so:

```elixir
System.cmd("/sbin/devmem", ["0x11C1010", "32"])
```

Registers owned by a driver can also be read without `devmem`, through regmap's
debugfs — `/sys/kernel/debug/regmap/1100000.mixer-{layers,top,display}`, after
`mount -t debugfs none /sys/kernel/debug`. That covers the mixer windows,
including the whole UI layer block below, but **not** the DE clock window at
`0x1008000`: no driver exposes a regmap for it, which is exactly why `devmem`
had to come back.

**The UI layer block is the priority.** It has never been read on either side,
and it is where "does the display engine even have the pixels" becomes a direct
question. Expected values here are derived from mainline's source for fbcon's
640×480 `XR24` buffer at pitch 2560:

| Address | Register | Expected here |
|---|---|---|
| `0x11C1000` | layer 0 `ATTR` | bit 0 set (layer enabled), format field `XRGB8888` at bits 8–12 |
| `0x11C1004` | layer 0 `SIZE` | `0x01DF027F` |
| `0x11C1008` | layer 0 `COORD` | `0x00000000` |
| `0x11C100C` | layer 0 `PITCH` | `0x00000A00` (2560) |
| `0x11C1010` | layer 0 `TOP_LADDR` | **a framebuffer address, `0x4xxxxxxx`** |
| `0x11C1080` | `TOP_HADDR` | `0x00000000` |
| `0x11C1088` | `OVL_SIZE` | `0x01DF027F` |

`TOP_LADDR` is the single most informative word in the whole stack right now. If
it is zero or implausible, the DE is being pointed at nothing and the fault is
above the hardware. If it holds a sane DRAM address, then the DE has been told
where the pixels are and still does not fetch them, which points at the fetch
path or an enable rather than at configuration.

A note on `ATTR` bit 0: mainline rewrites the layer enable on every commit, with
the comment "it can clear spontaneously for unknown reasons". Reading it back as
**0** on a supposedly enabled plane would be worth more than any other single
result here.

Then, in order:

1. **`0x1281080`, `0x1281088`, `0x128108C`** — `BLEND_ROUTE`, `BLEND_BKCOLOR`
   and `BLEND_OUTSIZE`, the three blender registers that were never actually
   compared. Cheap, and one of them decides whether "the blender matches the
   vendor" is a claim or an assumption.
2. **`0x1008010`** — the DE→TCON mux. Mainline never writes it; neither side has
   ever read it.
3. **`0x1008008`** — the MBUS clock, to confirm the accident described above.
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

It also narrows where a bug can still be hiding. Mainline's register *map* is
now confirmed against the vendor's own structs for the blender, the channel
bases and the UI layer — so a wrong offset is no longer a live theory anywhere
except the top block, and there the DE2 tables land on the right bits by
coincidence. What remains is a wrong *value*, a missing write, or an ordering
problem, and the measurement list above is arranged to tell those apart.
