#!/bin/bash
#
# Test check-gpu-stack.sh against synthetic trees, in seconds, with no build.
#
# ## Why this exists
#
# check-gpu-stack.sh runs as the last step of a three-and-a-half hour job, so
# a one-line shell mistake in it costs three and a half hours to discover. That
# happened twice in one day: run 32008727891 spent 3h24m building a correct
# system and then failed because the checker was wrong, and the fix cost
# another full build to confirm.
#
# Nothing about the checker needs a build. It needs a directory of the right
# shape, and those can be made here in about a second. This runs in the cheap
# `checks` job, on every push.
#
# ## The fixtures are load-bearing, and were wrong once
#
# The bug this was written for: `tar -tf big.tar | grep -q PATTERN` under
# `set -o pipefail`. grep exits on match and closes the pipe, tar is killed by
# SIGPIPE and exits 141, pipefail promotes that to the pipeline's status, and a
# match that happened is reported as a miss.
#
# That only fires when tar still has substantial output to write *after* the
# match. Filler that sorted *before* usr/bin/kmscube would land the match on
# the very last entry: tar has nothing left to write, no SIGPIPE, and the
# fixture passes the buggy code -- a self-test certifying the exact bug it was
# written to catch.
#
# So the filler lives under ./var/, which sorts after ./usr/bin/kmscube, and
# `test_fixture_reproduces_the_pipe_trap` asserts that the buggy idiom really
# does fail on it. If that assertion ever passes the buggy idiom, the fixture
# has stopped testing anything and says so.
#
# Pure shell, no Docker, no network. Note that it is only meaningful on a tar
# that dies on SIGPIPE: macOS bsdtar and Homebrew's GNU tar do not, so the
# pipe-trap test self-skips there rather than reporting a pass it did not earn.
#
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
subject="$here/check-gpu-stack.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

ok()   { echo "  ok       $1"; pass=$((pass + 1)); }
bad()  { echo "  FAILED   $1"; fail=$((fail + 1)); }
skip() { echo "  skipped  $1"; }

# -- fixtures ---------------------------------------------------------------

# A rootfs tarball shaped like Buildroot's: entries relative to the staging
# root with a ./ prefix, sorted, and enough of them after the match to matter.
# See the header -- the filler must sort AFTER usr/bin/kmscube.
make_rootfs() { # make_rootfs <dest.tar> <with_kmscube:yes|no>
    local dest=$1 with=$2 cached="$work/cache-rootfs-$2.tar"

    # Built once per variant and copied thereafter: rebuilding it for every
    # fixture -- eight tarballs, thousands of files each -- takes minutes, and
    # this runs in the cheap job whose entire purpose is fast feedback.
    if [ ! -f "$cached" ]; then
        local root="$work/rootfs-src-$2" list="$work/list-$2"
        mkdir -p "$root/usr/bin" "$root/var"
        : > "$list"
        [ "$with" = yes ] && echo './usr/bin/kmscube' >> "$list"

        # Long names on purpose. What makes the pipe trap fire is tar still
        # having more than a pipe buffer (64 KiB on Linux) left to write after
        # the matched line -- so it is bytes of listing that matter, not file
        # count. ~4000 entries of ~60 bytes is ~240 KB, comfortably over,
        # while short names would have needed several times as many files.
        local i
        for i in $(seq 1 4000); do
            echo "./var/filler_padding_to_make_this_line_longer_$i"
        done >> "$list"

        # One touch per 500 names rather than 4000 separate redirections.
        ( cd "$root" && sed 's|^\./||' "$list" | xargs -n 500 touch ) 2>/dev/null

        # The order is written out explicitly rather than produced by
        # find|sort, and only regular files are listed, so nothing recurses.
        # Buildroot uses `find -print0 | sort -z | tar --null --no-recursion
        # -T -`, which is GNU-only: bsdtar rejects --no-recursion, so on macOS
        # the tarball was silently never created. An -T list suits both.
        ( cd "$root" && tar -cf "$cached" -T "$list" ) 2>/dev/null
        rm -rf "$root" "$list"
    fi

    cp "$cached" "$dest"
}

# `panfrost` has to appear inside the megadriver, because that is what the
# subject greps for. Spelled out rather than interpolated: an earlier throwaway
# test wrote "not panfrost" into the *negative* fixture and the grep matched,
# reporting a swrast build as fine.
make_megadriver() { # make_megadriver <path> <panfrost:yes|no>
    if [ "$2" = yes ]; then
        printf 'gallium megadriver: panfrost radeonsi swrast\n' > "$1"
    else
        printf 'gallium megadriver: swrast only, software rasterisation\n' > "$1"
    fi
}

make_config() { # make_config <path> <complete:yes|no>
    {
        echo 'BR2_PACKAGE_MESA3D_GBM=y'
        echo 'BR2_PACKAGE_KMSCUBE=y'
        [ "$2" = yes ] && echo 'BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_PANFROST=y'
    } > "$1"
}

# A packaged artifact: staging/ and images/, no target/.
make_artifact() { # make_artifact <dir> <panfrost> <kmscube> <config_complete>
    local d=$1
    mkdir -p "$d/staging/usr/lib" "$d/images"
    : > "$d/staging/usr/lib/libgbm.so.1"
    : > "$d/staging/usr/lib/libEGL.so.1"
    : > "$d/staging/usr/lib/libGLESv2.so.2"
    make_megadriver "$d/staging/usr/lib/libgallium-26.1.2.so" "$2"
    make_rootfs "$d/images/rootfs.tar" "$3"
    make_config "$d/.config" "$4"
}

# A Buildroot output tree: target/ as well, which the subject prefers.
make_build_tree() { # make_build_tree <dir> <panfrost> <kmscube_in_image>
    local d=$1
    mkdir -p "$d/target/usr/lib" "$d/target/usr/bin" "$d/images"
    : > "$d/target/usr/bin/kmscube"
    : > "$d/target/usr/lib/libgbm.so.1.0.0"
    : > "$d/target/usr/lib/libEGL.so.1"
    : > "$d/target/usr/lib/libGLESv2.so.2"
    make_megadriver "$d/target/usr/lib/libgallium-26.1.2.so" "$2"
    make_rootfs "$d/images/rootfs.tar" "$3"
    make_config "$d/.config" yes
}

buildlog() { # buildlog <path> <complete:yes|no>
    {
        echo '>>> host-mesa3d 26.1.2 Building'
        [ "$2" = yes ] && echo '>>> kmscube 0.0.1 Building'
    } > "$1"
}

# -- helpers ----------------------------------------------------------------

run() { # run <args...> ; sets $out and $rc
    out=$("$subject" "$@" 2>&1)
    rc=$?
}

expect_rc() { # expect_rc <wanted> <description>
    if [ "$rc" -eq "$1" ]; then
        ok "$2"
    else
        bad "$2 (exit $rc, wanted $1)"
        echo "$out" | sed 's/^/             /'
    fi
}

expect_says() { # expect_says <pattern> <description>
    if echo "$out" | grep -qF "$1"; then
        ok "$2"
    else
        bad "$2 -- nothing said \"$1\""
        echo "$out" | sed 's/^/             /'
    fi
}

expect_silent_about() { # expect_silent_about <pattern> <description>
    if echo "$out" | grep -qF "$1"; then
        bad "$2 -- it said \"$1\""
        echo "$out" | sed 's/^/             /'
    else
        ok "$2"
    fi
}

echo "==> the fixture itself"

# Before anything else, two questions in the right order.
#
# First: is the fixture sound? This gate is not ceremony. Without it, a
# tarball that failed to be created also makes the piped idiom report a miss,
# so the pipe-trap assertion below passes -- a self-test reporting success
# because its fixture is broken, which is the exact failure it exists to
# catch. That happened: the GNU-only tar flags produced no archive on macOS and
# this said "ok".
t=$work/trap; mkdir -p "$t"; make_rootfs "$t/rootfs.tar" yes
fixture_ok=no
if ! tar -tf "$t/rootfs.tar" > "$work/trap-list" 2>/dev/null; then
    bad "the fixture tarball is not readable -- every test below is meaningless"
elif ! grep -qE '^(\./)?usr/bin/kmscube$' "$work/trap-list"; then
    bad "the fixture tarball has no kmscube entry -- it is not the shape intended"
elif [ "$(grep -c . "$work/trap-list")" -lt 1000 ]; then
    bad "the fixture tarball is too small to leave output after the match"
else
    entries=$(grep -c . "$work/trap-list")
    at=$(grep -nE '^(\./)?usr/bin/kmscube$' "$work/trap-list" | cut -d: -f1)
    ok "fixture is sound: kmscube at $at of $entries, $((entries - at)) entries after it"
    fixture_ok=yes
fi

# Second, and only if the fixture is sound: does it still trip the trap the
# subject is written to avoid? If not, the assertions below prove less than
# they look like they do.
if [ "$fixture_ok" = yes ]; then
    piped=$( set -euo pipefail
             tar -tf "$t/rootfs.tar" 2>/dev/null |
                 grep -qE '^\./usr/bin/kmscube$' && echo match || echo miss )
    if [ "$piped" = miss ]; then
        ok "the fixture reproduces the pipe trap (old idiom reports a miss on a hit)"
    else
        skip "this tar survives SIGPIPE, so the pipe trap cannot be reproduced here"
        skip "  -- run on Linux with GNU tar for that assertion to mean anything"
    fi
fi

echo "==> a good system passes"

d=$work/good; make_artifact "$d" yes yes yes
run "$d"
expect_rc 0 "packaged artifact with the whole GPU stack"
expect_says "kmscube is in the rootfs image" "kmscube is found through the tarball"
expect_says "panfrost is inside" "panfrost is found inside the megadriver"

d=$work/goodbuild; make_build_tree "$d" yes yes; buildlog "$work/bl-good" yes
run "$d" "$work/bl-good"
expect_rc 0 "Buildroot output tree with the whole GPU stack"
expect_says "inspecting a Buildroot output tree" "the build layout is recognised"

echo "==> a broken system fails, for the right reason each time"

d=$work/swrast; make_artifact "$d" no yes yes
run "$d"
expect_rc 1 "a swrast-only Mesa fails"
expect_says "swrast-only Mesa" "and says the megadriver has no panfrost"

d=$work/nokmscube; make_build_tree "$d" yes no
run "$d"
expect_rc 1 "kmscube built but missing from the image fails"
expect_says "built, but not in the image" "and distinguishes that from never built"

d=$work/deselected; make_artifact "$d" yes yes no
run "$d"
expect_rc 1 "a Kconfig deselect fails"
expect_says "Kconfig deselected it" "and names the symbol"

echo "==> an unreadable input says so, rather than blaming the GPU"

d=$work/corrupt; make_artifact "$d" yes yes yes
printf 'this is not a tar archive at all\n' > "$d/images/rootfs.tar"
run "$d"
expect_says "no conclusion about what shipped" "a corrupt tarball is reported as unreadable"
expect_silent_about "the GPU chain did not build" "and is not blamed on the GPU"

d=$work/notree; mkdir -p "$d"
run "$d"
expect_rc 2 "a directory that is neither layout is a usage error, not a failure"

run "$work/does-not-exist"
expect_rc 2 "a missing directory is a usage error"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
