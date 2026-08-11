#!/bin/bash
#
# Regenerate linux/linux-<series>.defconfig from linux/nerves.fragment.
#
#   make ARCH=arm64 defconfig
#   scripts/kconfig/merge_config.sh -m .config linux/nerves.fragment
#   make ARCH=arm64 olddefconfig savedefconfig
#
# Runs in Docker so the result does not depend on what happens to be
# installed on the host, and so it works on macOS at all. Also verifies that
# every symbol the fragment asks for survived olddefconfig, and that the
# boot-critical drivers are present -- it exits non-zero if not.
#
# Usage: tools/gen-kernel-defconfig.sh [kernel-version]
#
set -euo pipefail

KVER="${1:-6.18.44}"
KMAJOR="${KVER%%.*}"
SERIES="$(echo "$KVER" | cut -d. -f1,2)"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="linux/linux-${SERIES}.defconfig"

echo "Generating $OUT for Linux $KVER"

docker run --rm \
  -v "$REPO_DIR:/repo" \
  -e KVER="$KVER" -e KMAJOR="$KMAJOR" -e SERIES="$SERIES" -e OUT="$OUT" \
  -w /build \
  debian:stable \
  bash /repo/tools/gen-kernel-defconfig-inner.sh

echo "Wrote $OUT"
