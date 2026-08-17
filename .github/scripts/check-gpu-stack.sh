#!/bin/bash
#
# Assert that a built system actually contains the GPU stack, by looking at
# the image rather than at the configuration that asked for it.
#
#   $1  a Buildroot output directory, or an unpacked Nerves artifact
#       (.nerves/artifacts/nerves_system_rg40xxv-portable-<version>, or
#        ~/.nerves/artifacts/... when one was downloaded rather than built)
#   $2  optional build log to scan for positive build evidence
#       (Nerves writes ./build.log while `mix compile` runs). Absent for a
#       downloaded artifact, which is not a failure -- see the end of the file.
#
# ## Two layouts, one check
#
# It takes either shape on purpose. `mix deps.get` downloads a prebuilt
# artifact whenever one matching the package checksum is published, and then
# `mix compile` builds nothing -- so on a re-run, or on a tag pointing at an
# already-released commit, there is no Buildroot tree to look at. CI used to
# stop there with "found 0 output directories", which is red for a reason that
# has nothing to do with the GPU.
#
# Checking the downloaded artifact instead is not a workaround, it is better:
# those are the bytes that will actually be flashed. A fresh build proves the
# tree can produce a good image; the artifact proves the published one *is*
# a good image.
#
# What the two layouts share is staging/, images/ and .config. Only target/
# and build/ are missing from a packaged artifact, and kmscube ships inside
# images/rootfs.tar either way -- so the checks below prefer target/ when it
# exists, because that path is proven, and fall back to staging/ plus the
# rootfs tarball when it does not.
#
# Why this exists, and why it does not trust .config:
#
# Until the Buildroot patch was applied in CI, every "green" run since cc1da1e
# shipped a swrast-only Mesa and nobody noticed. nerves_defconfig asked for
# BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_PANFROST=y, BR2_PACKAGE_MESA3D_GBM=y and
# BR2_PACKAGE_KMSCUBE=y, but unpatched Buildroot 2026.05.1 has panfrost
# `depends on BR2_PACKAGE_MESA3D_LLVM`, so Kconfig silently discarded the
# option and everything selected through it went with it. Run 31914168299 --
# reported as a success, 346 MB artifact uploaded -- contains no "panfrost",
# no "llvm", no host-mesa3d and no kmscube anywhere in its log.
#
# The lesson recorded in docs/superpowers/specs/2026-08-16-verification-plan.md
# is that .config said the build was correct while the image was not, so the
# checks below are ordered accordingly: the Kconfig grep is only a secondary
# line, kept so that a Kconfig deselect (nothing was ever asked for) reports
# differently from a build or staleness failure (asked for, never shipped).
#
# Note on the megadriver: Mesa 26.1.2 installs ONE libgallium-26.1.2.so rather
# than per-driver *_dri.so files, verified on hardware. So a filename check
# would prove nothing -- panfrost has to be looked for *inside* the shared
# object.
#
# Pure shell, no Docker, no network.
#
set -euo pipefail

build=${1:-}
buildlog=${2:-}

if [ -z "$build" ]; then
    echo "usage: $0 <buildroot output directory> [build log]" >&2
    exit 2
fi
if [ ! -d "$build" ]; then
    echo "no such build directory: $build" >&2
    exit 2
fi

config=$build/.config
rootfs=$build/images/rootfs.tar

rc=0
ok()   { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; rc=1; }

# Which tree holds the target libraries. A Buildroot output directory has
# target/, which is the proven path and stays primary; a packaged artifact
# does not, and staging/ carries the same shared objects.
if [ -d "$build/target" ]; then
    target=$build/target
    layout=build
elif [ -d "$build/staging" ]; then
    target=$build/staging
    layout=artifact
else
    echo "$build has neither target/ nor staging/ -- not a system build or artifact" >&2
    ls -la "$build" >&2 || true
    exit 2
fi

case "$layout" in
    build)    echo "==> inspecting a Buildroot output tree ($build)" ;;
    artifact) echo "==> inspecting a packaged artifact ($build)"
              echo "    No target/ here, so libraries are checked in staging/ and"
              echo "    kmscube in images/rootfs.tar. These are the bytes that ship." ;;
esac

# Every path below is a glob, not a pinned filename, because the exact target
# layout is inferred from Buildroot convention. On a miss, search the whole
# target tree for the same basename so that a wrong guess reports as a wrong
# path rather than as a missing feature.
check_glob() { # check_glob <description> <glob>
    local desc=$1 glob=$2 hits elsewhere
    hits=$(compgen -G "$glob" || true)
    if [ -n "$hits" ]; then
        ok "$desc: $(echo "$hits" | head -1 | sed "s|^$build/||")"
        return 0
    fi
    elsewhere=$(find "$target" -name "$(basename "$glob")" 2>/dev/null | head -3 || true)
    if [ -n "$elsewhere" ]; then
        fail "$desc: not at ${glob#"$build"/} but found at:"
        echo "$elsewhere" | sed 's|^|             |'
    else
        fail "$desc: nothing matches ${glob#"$build"/}"
    fi
    return 1
}

echo "==> the image (what actually shipped)"

# kmscube is the cheapest single tell: it links GBM, EGL and GLES, so it
# cannot exist unless all three were built. It is absent from every green run
# to date.
#
# Checked in images/rootfs.tar rather than in target/, because that tarball is
# the filesystem the device boots. target/ is Buildroot's staging area for it,
# and post-build.sh and the rootfs overlay run between the two -- so a file in
# target/ has not necessarily shipped. It also happens to be the one place
# both layouts agree on: a packaged artifact has no target/usr/bin at all.
if [ -f "$rootfs" ]; then
    if tar -tf "$rootfs" 2>/dev/null | grep -qE '^\./usr/bin/kmscube$'; then
        ok "kmscube is in the shipped rootfs (images/rootfs.tar)"
    else
        fail "kmscube is not in images/rootfs.tar -- the GPU chain did not build"
    fi
else
    fail "no images/rootfs.tar in $build -- cannot see what shipped"
fi

# And in target/ as well when there is one, so that "built but excluded from
# the image" reads differently from "never built".
if [ "$layout" = build ]; then
    check_glob "kmscube was staged for the image" "$target/usr/bin/kmscube" || true
fi

check_glob "libgbm"    "$target/usr/lib/libgbm.so.1*"     || true
check_glob "libEGL"    "$target/usr/lib/libEGL.so.1*"     || true
check_glob "libGLESv2" "$target/usr/lib/libGLESv2.so.2*"  || true

mega=$(compgen -G "$target/usr/lib/libgallium-*.so" || true)
if [ -z "$mega" ]; then
    # Fall back to a whole-tree search before calling it missing, the same way
    # check_glob does. Mesa could reasonably install this somewhere other than
    # usr/lib, and "we guessed the path wrong" must not report as "the GPU
    # driver is absent" -- that is the confusion this whole script exists to
    # stop, and it would be embarrassing to reproduce it here.
    mega=$(find "$target" -name 'libgallium-*.so' 2>/dev/null || true)
    if [ -n "$mega" ]; then
        fail "libgallium not at target/usr/lib but found at: $(echo "$mega" | tr '\n' ' ')"
    fi
fi

if [ -z "$mega" ]; then
    fail "no libgallium-*.so megadriver anywhere in the target tree"
else
    found_panfrost=0
    for so in $mega; do
        # -a: the megadriver is binary, and grep would otherwise just say
        # "binary file matches" on stdout and nothing useful on a miss.
        if grep -qa panfrost "$so"; then
            ok "panfrost is inside $(basename "$so")"
            found_panfrost=1
        fi
    done
    if [ "$found_panfrost" -eq 0 ]; then
        fail "libgallium-*.so contains no panfrost -- this is a swrast-only Mesa"
    fi
fi

echo "==> Kconfig (secondary: what was asked for, not what shipped)"

# If these are missing, the patch never reached the tree that configured this
# build and Kconfig dropped the options without a word. If these are present
# but the image checks above failed, the options survived configuration and
# the failure is in the build or in a stale output directory -- a different
# problem with a different fix.
if [ ! -f "$config" ]; then
    # Both layouts carry .config -- a packaged artifact keeps it, which is why
    # this secondary check still works when nothing was built. So its absence
    # is not the downloaded-artifact case; it means this directory is neither,
    # and the checks above were looking at something unexpected.
    fail "no .config in $build -- neither a Buildroot output tree nor a"
    fail "packaged artifact. The image checks above may be meaningless."
else
    for sym in \
        BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_PANFROST \
        BR2_PACKAGE_MESA3D_GBM \
        BR2_PACKAGE_KMSCUBE
    do
        if grep -q "^${sym}=y" "$config"; then
            ok "$sym survived Kconfig"
        else
            fail "$sym is not =y in the generated .config -- Kconfig deselected it"
        fi
    done
fi

if [ -n "$buildlog" ]; then
    echo "==> build log (positive evidence, not absence)"

    if [ ! -f "$buildlog" ] && [ "$layout" = artifact ]; then
        # Nothing was built, so there is nothing to have logged. Skipping is
        # correct here; failing would make a correct artifact look broken, and
        # that confusion is the reason this branch exists at all.
        echo "  skipped  no build log, and nothing was built -- this is a"
        echo "           downloaded artifact. The image checks above still ran."
    elif [ ! -f "$buildlog" ]; then
        fail "no build log at $buildlog, but this is a build tree -- one was expected"
    else
        # Nerves filters Buildroot's output down to its '>>>' progress lines,
        # which is why the silent deselect was invisible: there is no Kconfig
        # warning to find. These two lines are the positive confirmation --
        # neither appears in any green run before the patch was applied.
        grep -q '>>> host-mesa3d' "$buildlog" \
            && ok "host-mesa3d was built (the shader precompiler the patch relies on)" \
            || fail "host-mesa3d never built -- the panfrost chain was not configured"
        grep -q '>>> kmscube' "$buildlog" \
            && ok "kmscube was built" \
            || fail "kmscube never built"
    fi
fi

echo
if [ "$rc" -eq 0 ]; then
    echo "GPU stack is present in the image"
else
    echo "GPU STACK CHECK FAILED"
    echo
    # The paths above are inferred, so make the first failing run diagnostic
    # rather than merely red.
    echo "For reference, GPU-ish files that are in the image:"
    find "$target" \
        \( -name 'libgallium*' -o -name 'libEGL*' -o -name 'libGLES*' \
           -o -name 'libgbm*' -o -name 'kmscube' -o -name '*_dri.so' \) \
        2>/dev/null | sed 's|^|  |' | head -40 || true
fi
exit $rc
