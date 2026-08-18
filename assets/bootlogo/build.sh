#!/bin/sh
#
# Regenerate bootlogo.png from the four vendored source logos.
#
# The strip is what BR2_LINUX_KERNEL_CUSTOM_LOGO_PATH points at; Buildroot
# converts it to drivers/video/logo/logo_linux_clut224.ppm (224 colours,
# no dither) at kernel build time, and fbcon draws it at the top of the
# panel when it takes the console -- about 2.4 s into boot on this board.
#
# Layout constraints, in order of importance:
#
#  - fbcon draws n copies of the logo where n * (width + 8) - 8 <= xres.
#    The panel is 640 wide, so any strip wider than 316 px is drawn exactly
#    once. This is what turns "four Tuxes" (one per CPU) into one strip.
#
#  - Each mark is scaled but otherwise unaltered, and clearly separated
#    from its neighbours. The Elixir and Nerves trademark policies forbid
#    visually combining their logos with other images; a row of distinct,
#    unmodified marks saying "this runs Linux, Erlang, Elixir and Nerves"
#    is the nominative use both policies explicitly permit, and the
#    separation is what keeps it a row of marks rather than a new one.
#    Do not use this strip as this project's own logo anywhere.
#
#  - The background is black because that is fbcon's background; the
#    Erlang tile carries its own white rounded box (that is Ericsson's
#    file, unaltered).
#
set -eu
cd "$(dirname "$0")"

magick erlang-logo128.png -resize x80 /tmp/bootlogo-erl.png
# The drop-only official logo (from elixir-lang/elixir's own docs pages, the
# exact file upstream annotates with the trademark-policy LicenseRef). The
# full drop+wordmark lockup made Elixir twice the width of every other mark.
magick elixir-drop.png    -resize x80 /tmp/bootlogo-eli.png
magick nerves-icon.png    -resize x80 /tmp/bootlogo-ner.png

magick -background black \
    tux.png /tmp/bootlogo-erl.png /tmp/bootlogo-eli.png /tmp/bootlogo-ner.png \
    -gravity center +smush 36 \
    -bordercolor black -border 16x10 \
    bootlogo.png

rm -f /tmp/bootlogo-erl.png /tmp/bootlogo-eli.png /tmp/bootlogo-ner.png
magick identify -format "bootlogo.png %wx%h\n" bootlogo.png
