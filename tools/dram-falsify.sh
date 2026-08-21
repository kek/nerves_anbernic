#!/bin/bash
#
# Test the DRAM type by trying to be wrong about it.
#
# tools/dram-type.sh establishes that this board is LPDDR3 two ways: the vendor
# boot0 declares it, and the controller in the running device is driving it.
# Both are positive evidence. This is the negative control -- it builds SPLs
# configured for the types the board is *not*, runs each one, and shows that
# DRAM does not come up.
#
# That matters because the two claims in circulation cannot both be true.
# Anbernic's own specifications say the H700 family is uniformly 1 GB LPDDR4,
# and one plausible reconciliation is that our dram type setting is inert --
# that DRAM init happens in a vendor blob and the Kconfig symbol is never
# consulted, so LPDDR3 and LPDDR4 would both "work".
#
# Run on 2026-08-21, with the three outcomes written down before the device was
# touched. The result:
#
#   lpddr3            DRAM up, 0x40000000 and 0x40100000 independent
#   lpddr4-upstream   SPL hung in DRAM init
#   lpddr4-typeonly   SPL hung in DRAM init
#   ddr3-typeonly     SPL hung in DRAM init
#
# So the symbol is not inert -- the two type-only variants change nothing but
# the protocol, same clock and ODT and drive strengths and TPR words, and they
# turn a working init into a hang. A value that is never consulted cannot do
# that. And the die is not LPDDR4: lpddr4-upstream is the exact configuration
# upstream ships for the H700 Anbernic the specifications call identical
# hardware, and it does not train this memory.
#
# Why FEL and not firmware
# ------------------------
# uboot/uboot.defconfig is inside checksum_files(), so editing it invalidates
# the system artifact and costs a full Buildroot rebuild. Worse, fwup.conf
# writes the SPL only in the "complete" task, so `mix upload` cannot deliver a
# different SPL at all -- it needs `mix burn`, a card out and back, per attempt.
#
# `sunxi-fel spl` uploads an SPL into SRAM and runs it there. The SD card is
# never touched, nothing is flashed, and a hang costs a power cycle. This is
# the same technique that found the LPDDR3 bug; docs/debugging.md has it.
#
# What a result means
# -------------------
# A variant "brings up DRAM" only if two addresses 1 MB apart round-trip
# independently. `readl` answering is not enough: wrong geometry with right
# timings gives a DRAM that answers, aliases, and corrupts Linux later. That
# distinction is why the second address is here.
#
# A variant whose SPL hangs takes the device off USB, which is the expected
# result for a wrong type and is reported as such rather than as an error.
#
#   tools/dram-falsify.sh build     build the SPL variants (needs Docker)
#   tools/dram-falsify.sh test <n>  FEL-test one variant by name
#   tools/dram-falsify.sh matrix    walk every variant, prompting between
#   tools/dram-falsify.sh variants  list what has been built
#
# Putting the device in FEL mode: power on with **no SD card** and connect
# USB-C. The H700 reports as H616, SoC ID 0x1823.
#
set -euo pipefail

cd "$(dirname "$0")/.."

WORK=${DRAM_FALSIFY_WORK:-.dram-falsify}
IMAGE=rg40xxv-uboot-spl
UBOOT_TARBALL=${UBOOT_TARBALL:-$HOME/.nerves/dl/uboot/u-boot-2026.04.tar.bz2}

# The variants, and what each one is asking. The two "typeonly" ones change
# nothing but the protocol -- same clock, same drive strengths, same ODT, same
# TPR words -- which is what makes them a clean test of whether the symbol is
# consulted at all. The upstream one is the whole DRAM block from
# configs/anbernic_rg35xx_h700_defconfig, i.e. the configuration that should
# work if the family specification is right about this unit.
VARIANTS="lpddr3 lpddr4-upstream lpddr4-typeonly ddr3-typeonly"

expected() { # expected <variant>
    case "$1" in
        lpddr3)          echo "DRAM comes up (this is the control)" ;;
        lpddr4-upstream) echo "no DRAM, if this board is not LPDDR4" ;;
        lpddr4-typeonly) echo "no DRAM, and if it does come up the symbol is inert" ;;
        ddr3-typeonly)   echo "no DRAM, and if it does come up the symbol is inert" ;;
    esac
}

# What the matrix actually did on 2026-08-21, on the one unit that exists here.
# Recorded so a later run is a regression test rather than a fresh opinion: if
# the DRAM values are ever changed, this matrix should still come out this way,
# and a variant that disagrees with its recorded outcome is the finding.
recorded() { # recorded <variant>
    case "$1" in
        lpddr3)          echo "up" ;;
        lpddr4-upstream) echo "hung" ;;
        lpddr4-typeonly) echo "hung" ;;
        ddr3-typeonly)   echo "hung" ;;
    esac
}

describe_outcome() { # describe_outcome <outcome>
    case "$1" in
        up)      echo "DRAM up, two addresses 1 MB apart independent" ;;
        hung)    echo "SPL did not return -- DRAM init hung" ;;
        alias)   echo "DRAM answers but aliases" ;;
        no-rt)   echo "DRAM did not round-trip" ;;
        no-fel)  echo "no device in FEL mode" ;;
        *)       echo "$1" ;;
    esac
}

# Compare against the record and say so either way. A run that reproduces is
# worth printing: this whole tool exists because "it worked" was doing too much
# unexamined work.
compare() { # compare <variant> <outcome>
    local want; want=$(recorded "$1")
    if [ "$2" = "$want" ]; then
        note "matches the outcome recorded on 2026-08-21 ($want)"
    else
        fail "recorded outcome for $1 was '$want', this run gave '$2'"
        note "that is a real change -- $(describe_outcome "$want") was expected"
    fi
}

rc=0
ok()   { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; rc=1; }
note() { echo "  ..       $1"; }

need() { command -v "$1" >/dev/null || { echo "need $1 on PATH"; exit 2; }; }

# ---------------------------------------------------------------- build ------

build() {
    need docker
    [ -r "$UBOOT_TARBALL" ] || { echo "no U-Boot tarball at $UBOOT_TARBALL"; exit 2; }

    mkdir -p "$WORK/out" "$WORK/ctx"

    # A Debian image rather than the host, because U-Boot's host tools want
    # OpenSSL headers, pylibfdt and swig, and on macOS pylibfdt fails to link
    # (the Python extension needs -undefined dynamic_lookup, which U-Boot's
    # setup.py does not pass). Buildroot builds U-Boot in Linux for the same
    # reason. This image is small and cached after the first run.
    cat > "$WORK/ctx/Dockerfile" <<'EOF'
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential gcc-aarch64-linux-gnu bison flex bc \
      libssl-dev python3 python3-dev python3-setuptools swig \
      device-tree-compiler libgnutls28-dev uuid-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
EOF
    echo "==> building the build image (cached after the first time)"
    docker build -q -t "$IMAGE" "$WORK/ctx" >/dev/null

    cat > "$WORK/ctx/inner.sh" <<'INNER'
#!/bin/bash
set -euo pipefail
export CROSS_COMPILE=aarch64-linux-gnu-
mkdir -p /work && cd /work
tar xjf /dl/*.tar.bz2
SRC=$(echo /work/u-boot-*)
BASE=/repo/uboot/uboot.defconfig

for v in $VARIANTS; do
    echo "==> $v"
    O="/work/b-$v"; mkdir -p "$O"
    case "$v" in
      lpddr3)          cp "$BASE" "$O/.config" ;;
      lpddr4-typeonly) sed 's/^CONFIG_SUNXI_DRAM_H616_LPDDR3=y$/CONFIG_SUNXI_DRAM_H616_LPDDR4=y/' "$BASE" > "$O/.config" ;;
      ddr3-typeonly)   sed 's/^CONFIG_SUNXI_DRAM_H616_LPDDR3=y$/CONFIG_SUNXI_DRAM_H616_DDR3_1333=y/' "$BASE" > "$O/.config" ;;
      lpddr4-upstream)
          grep -vE '^CONFIG_(DRAM_CLK|DRAM_SUNXI_(DX_ODT|DX_DRI|CA_DRI|ODT_EN|TPR2|TPR6|TPR10|TPR11|TPR12|PHY_ADDR_MAP_1)|SUNXI_DRAM_H616_LPDDR3)=' "$BASE" > "$O/.config"
          cat >> "$O/.config" <<'UP'
CONFIG_DRAM_CLK=672
CONFIG_DRAM_SUNXI_DX_ODT=0x08080808
CONFIG_DRAM_SUNXI_DX_DRI=0x0e0e0e0e
CONFIG_DRAM_SUNXI_CA_DRI=0x0e0e
CONFIG_DRAM_SUNXI_ODT_EN=0x7887bbbb
CONFIG_DRAM_SUNXI_TPR2=0x1
CONFIG_DRAM_SUNXI_TPR6=0x40808080
CONFIG_DRAM_SUNXI_TPR10=0x402f6633
CONFIG_DRAM_SUNXI_TPR11=0x1b1f1e1c
CONFIG_DRAM_SUNXI_TPR12=0x06060606
CONFIG_DRAM_SUNXI_PHY_ADDR_MAP_1=y
CONFIG_SUNXI_DRAM_H616_LPDDR4=y
UP
          ;;
    esac
    ( cd "$SRC" && make O="$O" olddefconfig >/dev/null )
    # Kconfig drops symbols whose dependencies are unmet, silently. Without
    # this line two variants could compile to the same thing and the matrix
    # would look like a result.
    got=$(grep -oE '^CONFIG_SUNXI_DRAM_H616_[A-Z0-9_]+=y' "$O/.config" || true)
    echo "    type symbol: ${got:-NONE SURVIVED}"
    if ( cd "$SRC" && make O="$O" -j"$(nproc)" spl/sunxi-spl.bin >/dev/null 2>"$O/err.log" ); then
        cp "$O/spl/sunxi-spl.bin" "/out/spl-$v.bin"
        echo "    built $(stat -c%s "/out/spl-$v.bin") bytes"
    else
        echo "    BUILD FAILED"; tail -15 "$O/err.log"
    fi
done
INNER

    docker run --rm \
        -e VARIANTS="$VARIANTS" \
        -v "$PWD/$WORK/out:/out" \
        -v "$(dirname "$UBOOT_TARBALL"):/dl:ro" \
        -v "$PWD:/repo:ro" \
        -v "$PWD/$WORK/ctx/inner.sh:/inner.sh:ro" \
        "$IMAGE" bash /inner.sh

    echo
    variants
}

variants() {
    echo "built variants in $WORK/out:"
    local any=0
    for v in $VARIANTS; do
        local f="$WORK/out/spl-$v.bin"
        if [ -r "$f" ]; then
            any=1
            printf '  %-18s %6s bytes  recorded: %s\n' "$v" "$(wc -c < "$f" | tr -d ' ')" "$(describe_outcome "$(recorded "$v")")"
        fi
    done
    [ "$any" -eq 1 ] || echo "  (none -- run 'build' first)"
}

# ----------------------------------------------------------------- test ------

fel() { # fel <args...> -- never allowed to wedge the script
    timeout 20 sunxi-fel "$@" 2>&1 || return $?
}

in_fel() {
    fel -l >/dev/null 2>&1
}

test_variant() { # test_variant <variant>
    need sunxi-fel
    local v="$1" img="$WORK/out/spl-$1.bin"
    [ -r "$img" ] || { echo "no image for '$v' -- run 'build' first"; exit 2; }

    echo "==> $v"
    echo "    expected: $(expected "$v")"
    echo

    if ! in_fel; then
        fail "no device in FEL mode"
        note "power on with no SD card and connect USB-C, then try again"
        return
    fi
    ok "device is in FEL mode: $(fel -l | head -1)"

    # If the SPL hangs the SoC, sunxi-fel either errors or the device leaves
    # the bus. Both are the same finding and neither is a script failure.
    if ! fel spl "$img" >/dev/null 2>&1; then
        echo
        echo "  RESULT   the SPL did not return -- DRAM init hung"
        note "this is what a wrong DRAM type looks like on this SoC"
        compare "$v" hung
        return
    fi
    ok "the SPL ran and returned"

    if ! in_fel; then
        echo
        echo "  RESULT   the device left the USB bus after running the SPL"
        note "hung after returning; still a failure to bring up DRAM"
        compare "$v" hung
        return
    fi

    # Two addresses 1 MB apart, each written and read back, then the first
    # re-read. Aliasing shows up as the second write having changed the first
    # location -- a DRAM that answers every address with the same cell.
    local a=0x40000000 b=0x40100000
    fel writel $a 0xcafebabe >/dev/null 2>&1 || true
    fel writel $b 0x5a5a5a5a >/dev/null 2>&1 || true
    local ra rb
    ra=$(fel readl $a | tr -d '\r' | tail -1)
    rb=$(fel readl $b | tr -d '\r' | tail -1)

    echo "    $a reads $ra (wrote 0xcafebabe)"
    echo "    $b reads $rb (wrote 0x5a5a5a5a)"
    echo

    if [ "$ra" = "0xcafebabe" ] && [ "$rb" = "0x5a5a5a5a" ]; then
        echo "  RESULT   DRAM came up and two addresses 1 MB apart are independent"
        compare "$v" up
    elif [ "$ra" = "$rb" ]; then
        echo "  RESULT   both addresses read the same -- DRAM answers but aliases"
        note "wrong geometry rather than wrong timings; boots and corrupts later"
        compare "$v" alias
    else
        echo "  RESULT   DRAM did not round-trip"
        compare "$v" no-rt
    fi
}

matrix() {
    echo "The falsification matrix. Between variants the device needs putting"
    echo "back into FEL mode: power off, remove the SD card if it is in, power"
    echo "on and connect USB-C."
    echo
    for v in $VARIANTS; do
        read -r -p "ready to test '$v'? [enter to run, s to skip, q to stop] " a
        case "$a" in
            q) break ;;
            s) echo "    skipped"; continue ;;
        esac
        test_variant "$v"
        echo
    done
}

case "${1:-}" in
    build)    build ;;
    variants) variants ;;
    test)     [ $# -eq 2 ] || { echo "usage: $0 test <variant>"; exit 2; }; test_variant "$2" ;;
    matrix)   matrix ;;
    *)        sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 2 ;;
esac

exit "$rc"
