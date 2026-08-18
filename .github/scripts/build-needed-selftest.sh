#!/bin/bash
#
# Test build-needed.sh against the real mix.exs, in about a second.
#
# The dangerous answer is "false": a build that is skipped is an image nothing
# verified, and the skip looks identical to a pass. That asymmetry is why this
# exists and why the cases below lean on the false answers -- every one of them
# is a claim that some file cannot affect the image, and each is only as good as
# the parse behind it.
#
set -euo pipefail

cd "$(dirname "$0")/../.."

rc=0
ok()   { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; rc=1; }

run() { printf '%s\n' "$1" | .github/scripts/build-needed.sh mix.exs 2>/dev/null; }

expect() { # expect <changed-paths> <true|false> <description>
    got=$(run "$1")
    if [ "$got" = "$2" ]; then ok "$3"; else fail "$3 (expected $2, got $got)"; fi
}

echo "==> things that cannot change the image"
expect ".github/workflows/ci.yml"          false "a workflow edit"
expect ".github/scripts/build-needed.sh"   false "this script itself"
expect "docs/display.md"                   false "a document"
expect "docs/superpowers/specs/x.md"       false "a spec"
expect "README.md"                         false "the README"
expect "CHANGELOG.md"                      false "the changelog"
expect ".gitignore"                        false "an untracked-files list"
expect "tools/check-consistency.sh"        false "a checker that runs in CI, not in the image"

echo "==> things that can"
expect "mix.exs"                           true  "mix.exs, which defines the build"
expect "VERSION"                           true  "VERSION"
expect "nerves_defconfig"                  true  "the Buildroot defconfig"
expect "linux/nerves.fragment"             true  "a kernel config fragment"
expect "linux/linux-6.18.defconfig"        true  "the generated kernel defconfig"
expect "patches/linux/0101-x.patch"        true  "a kernel patch"
expect "patches/buildroot/0002-x.patch"    true  "a Buildroot patch"
expect "rootfs_overlay/etc/erlinit.config" true  "a file installed into the image"
expect "uboot/uboot.defconfig"             true  "the U-Boot config"
expect "busybox/busybox.fragment"          true  "the busybox config"
expect "fwup.conf"                         true  "the image layout"
expect "fwup_include/fwup-common.conf"     true  "an included fwup fragment"
expect "LICENSES/BSD-2-Clause.txt"         true  "a licence text, matched by the LICENSES/* glob"
expect "post-build.sh"                     true  "the post-build hook"

echo "==> mixed and edge cases"
expect "$(printf 'docs/display.md\nlinux/nerves.fragment')" true \
    "one document and one real change still builds"
expect "$(printf 'docs/a.md\ndocs/b.md')" false \
    "several documents still do not"
expect ""                                  false "an empty change set"

# The prefix trap: "linux" is a directory entry, and a naive prefix test would
# have it swallow any path merely beginning with those letters.
expect "linuxfoo/bar"                      false "a path that only starts like a checksum entry"
expect "toolsy/x"                          false "the same trap for tools"

echo "==> the parse must be trusted only when it looks right"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# No checksum_files/0 at all.
sed 's/^  defp checksum_files do/  defp something_else do/' mix.exs > "$tmp/no-block.exs"
got=$(printf 'docs/x.md\n' | .github/scripts/build-needed.sh "$tmp/no-block.exs" 2>/dev/null)
if [ "$got" = "true" ]; then ok "an unreadable checksum_files() builds rather than skips"
else fail "an unreadable checksum_files() answered $got"; fi

# Present but gutted, which is what a half-working parser would produce.
awk '
    /^  defp checksum_files do/ { print; print "    ["; print "      \"VERSION\""; print "    ]"; print "  end"; skip = 1; next }
    skip && /^  end/ { skip = 0; next }
    !skip { print }
' mix.exs > "$tmp/short.exs"
got=$(printf 'docs/x.md\n' | .github/scripts/build-needed.sh "$tmp/short.exs" 2>/dev/null)
if [ "$got" = "true" ]; then ok "a suspiciously short checksum_files() builds rather than skips"
else fail "a short checksum_files() answered $got"; fi

echo
if [ $rc -eq 0 ]; then echo "build-needed.sh behaves"; else echo "build-needed.sh is wrong"; fi
exit $rc
