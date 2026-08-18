# The boot logo, and the terms of the four marks on it

The kernel boot logo is a strip: Tux, the Erlang logo, the Elixir logo and the
Nerves logo, side by side on black. fbcon draws it at the top of the panel the
moment it takes the console — about 2.4 s into boot on this board.

## Why a strip, and why it is drawn once

`CONFIG_LOGO` draws **n copies of one image**, where fbcon fits
`n * (width + 8) - 8 <= xres`. That is why a stock kernel on this quad-core
board showed four Tuxes. There is no mechanism for four *different* images —
but a single image wider than 316 px on this 640-wide panel can only fit once,
so the strip replaces "one logo, four times" with "four logos, once".

Buildroot does the embedding: `BR2_LINUX_KERNEL_CUSTOM_LOGO_PATH` in
`nerves_defconfig` names the PNG, and Buildroot converts it to
`drivers/video/logo/logo_linux_clut224.ppm` (224 colours, no dither) at kernel
build time, enabling `CONFIG_LOGO` itself. The conversion adds
`host-imagemagick` to the build. `assets/bootlogo/build.sh` regenerates the
strip from the four vendored sources; `tools/check-consistency.sh` asserts the
file exists at the path the defconfig names and that it is wide enough to be
drawn once.

## The terms, per mark

Researched 2026-08-18, sources linked. The short version: every one of these
uses is either copyright-licensed or explicitly permitted in writing by the
mark's owner, and each vendored file carries the same annotation its own
project uses for the identical artwork (see `REUSE.toml`).

**Tux** — created by Larry Ewing in 1996 with GIMP. Not a trademark: the
[Linux Foundation's mark program](https://www.linuxfoundation.org/legal/the-linux-mark)
covers only the word "Linux" and explicitly disclaims owning Tux. Ewing's
permission ([archived](https://web.archive.org/web/20080521142553/http://www.isc.tamu.edu/~lewing/linux/)):
*"Permission to use and/or modify this image is granted provided you
acknowledge me lewing@isc.tamu.edu and The GIMP if someone asks."* The
acknowledgment lives permanently in `LICENSES/LicenseRef-Larry-Ewing-Tux.txt`,
which is what satisfies "if someone asks". Our copy is the kernel's own
`logo_linux_clut224.ppm`.

**Erlang** — the word "ERLANG" is a registered trademark of
Telefonaktiebolaget LM Ericsson
([US Reg. 4,558,297](https://tsdr.uspto.gov/statusview/sn85816613), renewed
2024); the logo design itself is not registered. The copyright side is fully
cleared: Ericsson ships this exact file in `erlang/otp` with
[its own REUSE sidecar](https://github.com/erlang/otp/blob/master/lib/wx/priv/erlang-logo64.png.license)
declaring Apache-2.0, and every Linux distro already redistributes it. The
trademark side has a written answer from Ericsson via erlang.org's community
manager ([erlang/otp#3077](https://github.com/erlang/otp/issues/3077)): *"It is
okay for you to use the name Erlang and the unaltered Erlang logo … as long as
it is a nominative use … we want the trademarks to be used widely."*

**Elixir** — registered trademark
([USPTO Reg. 6392181](https://trademarks.justia.com/878/70/elixir-87870187.html)),
policy at [elixir-lang.org/trademarks](https://elixir-lang.org/trademarks). The
policy's first listed permitted use: *"Usage of the Elixir logo to say a
technology is 'powered by Elixir' under nominative use."* The vendored file is
the drop-only logo from `elixir-lang/elixir`'s own documentation pages — the
exact file whose upstream licence curation concludes
[`LicenseRef-elixir-trademark-policy`](https://github.com/elixir-lang/elixir/blob/main/LICENSES/LicenseRef-elixir-trademark-policy.txt).

**Nerves** — trademark of the Nerves Project Authors, policy at
[nerves-project.org/trademarks](https://nerves-project.org/trademarks/), which
permits the logo *"to say a technology is 'powered by Nerves'"* and *"to
display it as a supported technology in a service, platform, or hardware
device."* The core team ships a Buildroot boot-logo patch in
`nerves_system_br` and put the Nerves logo in the official EV3 system's kernel
boot themselves, and
[annotates its own logo artwork](https://github.com/nerves-project/nerves/blob/main/REUSE.toml)
exactly as this repository does.

## The one constraint that shapes the design

The Elixir and Nerves policies both say you *"must not visually combine the
logo with any other images."* The intent — clear from the surrounding text
about not creating derived marks — is to stop the logo becoming part of
someone else's identity, not to forbid side-by-side co-presentation, which
conference sponsor pages and "built with" footers do constantly. The strip
respects that reading mechanically:

- each mark is **unaltered** (scaled only — the policies allow changes
  "required by printing restrictions"),
- clearly **separated** from its neighbours on a plain background,
- and the strip is **never used as this project's own logo** — not in the
  README, not as an icon, nowhere but the boot screen it describes.

If certainty beyond a careful reading is ever wanted, the policies' own
channels are trademarks@elixir-lang.org and trademarks@nerves-project.org.

## Prior art, for calibration

The kernel's `drivers/video/logo/` has shipped DEC, SGI, Sun and SuperH
corporate logos in every tarball for over twenty years; its full git history
contains no trademark-motivated removal. Every documented logo enforcement
case in open source (Firefox/Iceweasel, Apache's cease-and-desists) concerned
products *named as* the mark, never a truthful "this runs X" display. No case
was found — anywhere — of a language or framework project objecting to its
logo in a "built with" context; Elixir and Nerves pre-authorise it in writing,
and Ericsson's only recorded statement asks for the marks "to be used widely".
