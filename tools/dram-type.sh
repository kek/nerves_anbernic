#!/bin/bash
#
# Settle whether this board's DRAM is LPDDR3 or LPDDR4.
#
# The question is not academic. anbernic_rg35xx_h700_defconfig upstream
# specifies CONFIG_SUNXI_DRAM_H616_LPDDR4, this system copied it verbatim, and
# the result was an SoC that stops responding inside DRAM init -- no FEL, no
# console, nothing. The answer is recorded in uboot/uboot.defconfig and in
# docs/bring-up.md, and both of those are prose. This is the mechanical check
# behind them.
#
# Three subcommands, two of which are decoders and one of which reads a
# register off a running device:
#
#   boot0 <file>     decode a vendor boot0. Offline, no hardware, definitive
#                    about what the firmware that boots this device programs.
#   mstr <hexword>   decode the DRAM controller's MSTR register, which says
#                    which protocol the controller is actually driving.
#   device [host]    read MSTR off a running device and decode it. Touches
#                    MMIO -- see the warning on that subcommand.
#   selftest         check both decoders against known vectors.
#
# What each check can and cannot prove
# ------------------------------------
# `boot0` reads the vendor's own bootloader off a card that boots this
# hardware. A sibling board's defconfig is a guess about this board; a
# firmware known to boot it is not. It proves what the manufacturer programs
# into this die, including the mode registers written into the chip itself.
#
# `mstr` proves what the controller in *this* running device is driving, which
# is the half a config file cannot tell you -- Kconfig silently demotes
# symbols, and this project has been bitten by exactly that. A device that is
# up, with a controller driving LPDDR3, is a die speaking LPDDR3: the two
# protocols are mutually unintelligible at the command level, so a mistyped
# controller does not train and does not serve reads.
#
# Neither reads the marking off the package. That is the only escalation left,
# and it is mechanical rather than logical.
#
# Sources for every constant below, so none of it rests on memory:
#
#   enum sunxi_dram_type { DDR3 = 3, DDR4, LPDDR3 = 7, LPDDR4 }
#   MSTR_DEVICETYPE_DDR3 BIT(0) / LPDDR2 BIT(2) / LPDDR3 BIT(3)
#                        / DDR4 BIT(4) / LPDDR4 BIT(5)
#   MSTR_BURST_LENGTH(x) (((x) >> 1) << 16)
#   MSTR_BUSWIDTH_FULL (0 << 12) / _HALF (1 << 12)
#   MSTR_ACTIVE_RANKS(x) (((x == 2) ? 3 : 1) << 24)
#     -- arch/arm/include/asm/arch-sunxi/dram_sun50i_h616.h
#
#   SUNXI_DRAM_CTL0_BASE 0x047FB000 under CONFIG_MACH_SUN50I_H616
#     -- arch/arm/include/asm/arch-sunxi/cpu_sun50i_h6.h
#
#   mstr = BIT(31) | BIT(30) | MSTR_BURST_LENGTH(8) | MSTR_DEVICETYPE_LPDDR3
#     for LPDDR3, and BURST_LENGTH(16) | DEVICETYPE_LPDDR4 for LPDDR4
#     -- arch/arm/mach-sunxi/dram_sun50i_h616.c, mctl_com_init()
#
#   LPDDR3 mode registers, mctl_phy_init(): MR1 = 0x83 ("nWR=14, BL8"),
#     MR2 = 0x1c, MR3 = 0x01. The LPDDR4 path writes an entirely different
#     sequence starting 0x0, 0x134.
#     -- arch/arm/mach-sunxi/dram_sun50i_h616.c
#
# Pure shell, awk and python3. No Docker, no network.
#
set -euo pipefail

cd "$(dirname "$0")/.."

rc=0
ok()   { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; rc=1; }
note() { echo "  ..       $1"; }

# The u-boot enum, and the MSTR device-type bits. Kept as two separate tables
# because they are two different encodings for the same question, and a tool
# that conflated them would agree with itself while being wrong.
dram_type_name() { # dram_type_name <n>
    case "$1" in
        3) echo "DDR3" ;;
        4) echo "DDR4" ;;
        7) echo "LPDDR3" ;;
        8) echo "LPDDR4" ;;
        *) echo "unknown" ;;
    esac
}

mstr_type_name() { # mstr_type_name <6-bit field>
    case "$1" in
        1)  echo "DDR3" ;;
        4)  echo "LPDDR2" ;;
        8)  echo "LPDDR3" ;;
        16) echo "DDR4" ;;
        32) echo "LPDDR4" ;;
        *)  echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------- boot0 ------

decode_boot0() { # decode_boot0 <file>
    local file="$1"

    if [ ! -r "$file" ]; then
        fail "cannot read $file"
        return
    fi

    echo "boot0: $file"

    # The whole decode lives in python3 because the checksum is a 32-bit sum
    # over 64 KiB and the struct is twelve little-endian words. It prints
    # `key=value` lines for the shell to assert on, so the parse and the
    # verdict stay separable.
    local out
    if ! out=$(python3 - "$file" <<'PY'
import struct, sys

STAMP = 0x5F0A6C39   # boot0's checksum placeholder, from Allwinner's gen_check_sum
FIELDS = ["clk", "type", "dx_odt", "dx_dri", "ca_dri", "odt_en",
          "para1", "para2", "mr0", "mr1", "mr2", "mr3"]
PARA_OFF = 0x38

b = bytearray(open(sys.argv[1], "rb").read())
if len(b) < 0x100:
    print("error=too short to be a boot0")
    raise SystemExit(0)

print("magic=%s" % bytes(b[4:12]).decode("latin1"))

stored = struct.unpack_from("<I", b, 0x0c)[0]
length = struct.unpack_from("<I", b, 0x10)[0]
print("length=%d" % length)
print("stored_checksum=0x%08x" % stored)

if length % 4 or length > len(b):
    print("checksum_ok=no")
else:
    # Substitute the stamp, sum `length` bytes as little-endian u32s. This is
    # the arithmetic that proves the header layout: it can only come out right
    # if the checksum field really is at 0x0c and the length field at 0x10.
    struct.pack_into("<I", b, 0x0c, STAMP)
    words = struct.unpack_from("<%dI" % (length // 4), b, 0)
    print("computed_checksum=0x%08x" % (sum(words) & 0xFFFFFFFF))
    print("checksum_ok=%s" % ("yes" if (sum(words) & 0xFFFFFFFF) == stored else "no"))

for i, name in enumerate(FIELDS):
    v = struct.unpack_from("<I", b, PARA_OFF + 4 * i)[0]
    print("para_%s=0x%08x" % (name, v))
PY
    ); then
        fail "python3 could not parse $file"
        return
    fi

    local magic checksum_ok
    magic=$(printf '%s\n' "$out" | awk -F= '$1=="magic"{print $2}')
    checksum_ok=$(printf '%s\n' "$out" | awk -F= '$1=="checksum_ok"{print $2}')

    if [ "$magic" = "eGON.BT0" ]; then
        ok "eGON.BT0 magic present"
    else
        fail "magic is '${magic}', not eGON.BT0 -- this is not a boot0"
        return
    fi

    if [ "$checksum_ok" = "yes" ]; then
        ok "checksum verifies over $(get "$out" length) bytes"
        note "so the blob is intact and the header layout is the documented one"
    else
        fail "checksum does not verify -- the image is damaged or not a boot0"
        note "stored $(get "$out" stored_checksum), computed $(get "$out" computed_checksum)"
        return
    fi

    local type clk name
    type=$(( $(get "$out" para_type) ))
    clk=$(( $(get "$out" para_clk) ))
    name=$(dram_type_name "$type")

    echo
    echo "  dram_para at 0x38:"
    for f in clk type dx_odt dx_dri ca_dri odt_en para1 para2 mr0 mr1 mr2 mr3; do
        printf '    %-7s %s\n' "$f" "$(get "$out" "para_$f")"
    done
    echo

    # Offset validation before believing anything in the struct. A wrong offset
    # would still yield twelve plausible-looking words, so the check is that
    # they agree with values established another way -- the clock, and the four
    # drive-strength and ODT words in our own working defconfig.
    if [ "$clk" -gt 0 ] && [ "$clk" -le 2000 ]; then
        ok "dram_clk = ${clk} MHz -- a plausible clock, so 0x38 is the struct"
    else
        fail "dram_clk = ${clk}, implausible -- 0x38 is not the struct here"
        return
    fi

    local mismatched=0
    for pair in "DRAM_CLK:clk" "DRAM_SUNXI_DX_ODT:dx_odt" \
                "DRAM_SUNXI_DX_DRI:dx_dri" "DRAM_SUNXI_CA_DRI:ca_dri" \
                "DRAM_SUNXI_ODT_EN:odt_en"; do
        local sym field want got
        sym=${pair%%:*}; field=${pair##*:}
        want=$(defconfig_value "$sym")
        got=$(( $(get "$out" "para_$field") ))
        if [ -z "$want" ]; then
            note "CONFIG_${sym} not set in uboot/uboot.defconfig, not compared"
        elif [ "$(( want ))" -eq "$got" ]; then
            ok "CONFIG_${sym} matches boot0's ${field}"
        else
            fail "CONFIG_${sym} is ${want} but boot0's ${field} is $(get "$out" "para_$field")"
            mismatched=1
        fi
    done
    [ "$mismatched" -eq 0 ] && note "five consecutive fields agreeing is the offset confirmed"

    # The mode registers are the strongest single signal in the blob: they are
    # what the vendor writes into the die itself, and u-boot's LPDDR3 and
    # LPDDR4 paths write nothing alike.
    local mr1 mr2 mr3
    mr1=$(( $(get "$out" para_mr1) ))
    mr2=$(( $(get "$out" para_mr2) ))
    mr3=$(( $(get "$out" para_mr3) ))
    if [ "$mr1" -eq $((0x83)) ] && [ "$mr2" -eq $((0x1c)) ] && [ "$mr3" -eq $((0x01)) ]; then
        ok "MR1/MR2/MR3 = 0x83/0x1c/0x01, byte-identical to u-boot's LPDDR3 sequence"
        note "MR1 = 0x83 encodes BL8; LPDDR4 is BL16 and its path writes 0x0, 0x134, ..."
    else
        note "MR1/MR2/MR3 = $(get "$out" para_mr1)/$(get "$out" para_mr2)/$(get "$out" para_mr3), not u-boot's LPDDR3 trio"
    fi

    echo
    case "$type" in
        7) echo "  VERDICT  dram_type = 7 = LPDDR3" ;;
        8) echo "  VERDICT  dram_type = 8 = LPDDR4" ;;
        3|4) echo "  VERDICT  dram_type = ${type} = ${name} -- non-LP, unexpected on this SoC" ;;
        *) fail "dram_type = ${type} is not a value in enum sunxi_dram_type"; return ;;
    esac
    echo "           per enum sunxi_dram_type in u-boot's dram_sun50i_h616.h"
}

get() { # get <key=value lines> <key>
    printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{print $2}'
}

defconfig_value() { # defconfig_value <symbol without CONFIG_>
    awk -F= -v s="CONFIG_$1" '$1==s{print $2}' uboot/uboot.defconfig 2>/dev/null || true
}

# ----------------------------------------------------------------- mstr ------

decode_mstr() { # decode_mstr <hex or decimal word>
    local word="$1"
    local val

    if ! val=$(( word )) 2>/dev/null; then
        fail "'$word' is not a number"
        return
    fi

    printf 'MSTR = 0x%08x\n' "$val"

    local type bl bw ranks
    type=$(( val & 0x3f ))
    bl=$(( ((val >> 16) & 0xf) * 2 ))
    bw=$(( (val >> 12) & 0x3 ))
    ranks=$(( (val >> 24) & 0x3 ))

    echo "  device type field  0x$(printf '%02x' "$type")  $(mstr_type_name "$type")"
    echo "  burst length       ${bl}"
    echo "  bus width          $([ "$bw" -eq 0 ] && echo full || echo "half ($bw)")"
    echo "  active ranks       $([ "$ranks" -eq 3 ] && echo 2 || echo 1)"
    echo

    # Reading two fields rather than one is the point. The device-type bits and
    # the burst length are written from the same switch arm in u-boot, so they
    # must agree; if they do not, something is reading the wrong address and
    # the friendly name above is noise.
    if [ "$type" -eq 8 ] && [ "$bl" -eq 8 ]; then
        echo "  VERDICT  the controller is driving LPDDR3"
        note "device type BIT(3) and BL8 agree, as u-boot writes them together"
    elif [ "$type" -eq 32 ] && [ "$bl" -eq 16 ]; then
        echo "  VERDICT  the controller is driving LPDDR4"
        note "device type BIT(5) and BL16 agree, as u-boot writes them together"
    elif [ "$val" -eq 0 ] || [ "$val" -eq $((0xffffffff)) ]; then
        fail "MSTR reads as $(printf '0x%08x' "$val") -- that is a dead read, not a register"
        note "the DRAM controller window may be secure-only or the address wrong"
    else
        fail "device type says $(mstr_type_name "$type") but the burst length is ${bl}"
        note "those two disagree, so this word is not a valid MSTR -- do not trust the name"
    fi
}

# --------------------------------------------------------------- device ------

read_device() { # read_device [host]
    local host="${1:-nerves.local}"
    local addr=0x047FB000   # SUNXI_DRAM_CTL0_BASE on H616, MSTR is at +0x000

    cat <<EOF
Reading MSTR at ${addr} on ${host}.

This reads one word of MMIO through busybox devmem. It is a read, and the
DRAM controller is a live and documented window -- but a stray MMIO read has
hung this SoC before (the 0x1200000 incident in HANDOFF.md), and recovery is a
power cycle. Nothing is written and nothing on disk is at risk.

EOF

    local out
    if ! out=$(ssh "$host" "System.cmd(\"devmem\", [\"${addr}\", \"32\"]) |> elem(0) |> String.trim() |> IO.puts()" 2>&1); then
        fail "could not read from ${host}"
        printf '%s\n' "$out" | sed 's/^/    /'
        return
    fi

    local word
    word=$(printf '%s\n' "$out" | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)
    if [ -z "$word" ]; then
        fail "no value came back from devmem"
        printf '%s\n' "$out" | sed 's/^/    /'
        return
    fi

    decode_mstr "$word"
}

# ------------------------------------------------------------- selftest ------

selftest() {
    echo "selftest"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # Synthesise boot0 images so the decoder is tested against inputs whose
    # answers are known by construction, including the ones it must refuse.
    make_boot0() { # make_boot0 <out> <dram_type> <break: none|checksum|magic>
        python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
out, dtype, brk = sys.argv[1], int(sys.argv[2]), sys.argv[3]
LEN = 0x1000
b = bytearray(LEN)
struct.pack_into("<I", b, 0x00, 0xea0004be)
b[4:12] = b"eGON.BT0" if brk != "magic" else b"NOTBOOT0"
struct.pack_into("<I", b, 0x10, LEN)
# dram_para: clk, type, dx_odt, dx_dri, ca_dri, odt_en, para1, para2, mr0..3
para = [672, dtype, 0x06060606, 0x0d0d0d0d, 0x00001919, 0x9988eeee,
        0x000030fa, 0x04000000, 0, 0x83, 0x1c, 0x01]
if dtype == 8:                      # an LPDDR4 blob would not carry LPDDR3 MRs
    para[8:12] = [0, 0x134, 0, 0]
for i, v in enumerate(para):
    struct.pack_into("<I", b, 0x38 + 4 * i, v)
struct.pack_into("<I", b, 0x0c, 0x5F0A6C39)
s = sum(struct.unpack_from("<%dI" % (LEN // 4), b, 0)) & 0xFFFFFFFF
struct.pack_into("<I", b, 0x0c, s if brk != "checksum" else (s ^ 0xFFFF))
open(out, "wb").write(b)
PY
    }

    expect_boot0() { # expect_boot0 <file> <substring> <description>
        local got
        got=$(decode_boot0 "$1" 2>&1 || true)
        if printf '%s\n' "$got" | grep -qF "$2"; then ok "$3"; else
            fail "$3 (no '$2' in output)"
            printf '%s\n' "$got" | sed 's/^/        /'
        fi
    }

    make_boot0 "$tmp/lpddr3.bin" 7 none
    make_boot0 "$tmp/lpddr4.bin" 8 none
    make_boot0 "$tmp/badsum.bin" 7 checksum
    make_boot0 "$tmp/badmagic.bin" 7 magic

    expect_boot0 "$tmp/lpddr3.bin" "VERDICT  dram_type = 7 = LPDDR3" "boot0 with type 7 reads as LPDDR3"
    expect_boot0 "$tmp/lpddr3.bin" "byte-identical to u-boot's LPDDR3 sequence" "the LPDDR3 mode registers are recognised"
    expect_boot0 "$tmp/lpddr4.bin" "VERDICT  dram_type = 8 = LPDDR4" "boot0 with type 8 reads as LPDDR4"
    expect_boot0 "$tmp/lpddr4.bin" "not u-boot's LPDDR3 trio" "an LPDDR4 blob is not credited with LPDDR3 mode registers"
    # The two refusals matter more than the two verdicts: a decoder that
    # answers confidently from a damaged blob is worse than one that answers
    # nothing, because the answer is what gets written into a defconfig.
    expect_boot0 "$tmp/badsum.bin" "FAILED   checksum does not verify" "a corrupted boot0 is refused, not decoded"
    expect_boot0 "$tmp/badmagic.bin" "not a boot0" "a file without the magic is refused"

    expect_mstr() { # expect_mstr <word> <substring> <description>
        local got
        got=$(decode_mstr "$1" 2>&1 || true)
        if printf '%s\n' "$got" | grep -qF "$2"; then ok "$3"; else
            fail "$3 (no '$2' in output)"
            printf '%s\n' "$got" | sed 's/^/        /'
        fi
    }

    # Built from u-boot's own expression, not from an observation:
    #   BIT(31)|BIT(30) | ACTIVE_RANKS(1) | BURST_LENGTH(8) | DEVICETYPE_LPDDR3
    #   = 0xc0000000 | 0x01000000 | 0x00040000 | 0x8
    expect_mstr 0xc1040008 "VERDICT  the controller is driving LPDDR3" "the LPDDR3 MSTR u-boot writes decodes as LPDDR3"
    expect_mstr 0xc1080020 "VERDICT  the controller is driving LPDDR4" "the LPDDR4 MSTR u-boot writes decodes as LPDDR4"
    expect_mstr 0x00000000 "dead read" "an all-zero word is called a dead read, not DDR3"
    expect_mstr 0xffffffff "dead read" "an all-ones word is called a dead read"
    # Device type LPDDR3 with LPDDR4's burst length: the shape of reading the
    # wrong address and getting something that half-looks right.
    expect_mstr 0xc1080008 "those two disagree" "type and burst length disagreeing is refused"
}

# ----------------------------------------------------------------- main ------

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'
    exit 2
}

case "${1:-}" in
    boot0)    [ $# -eq 2 ] || usage; decode_boot0 "$2" ;;
    mstr)     [ $# -eq 2 ] || usage; decode_mstr "$2" ;;
    device)   read_device "${2:-}" ;;
    selftest) selftest ;;
    *)        usage ;;
esac

echo
[ "$rc" -eq 0 ] && echo "all checks passed" || echo "something above failed"
exit "$rc"
