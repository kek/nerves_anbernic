#!/bin/bash
#
# Compile linux/sun50i-h700-anbernic-rg40xx-v.dts the way the kernel would,
# against a real kernel tree, and assert the resulting DTB actually describes
# the hardware we claim.
#
# This exists because the board DTS is almost entirely inherited: it is a
# 20-line extension of mainline's rg35xx-plus.dts. That makes it cheap to
# maintain but easy to break silently -- an upstream rename, or a stray edit,
# can leave a DTB that compiles and boots yet has no WiFi or the wrong model
# string. The assertions below are the things that would be invisible until
# someone flashed a card.
#
# Runs in Docker for a consistent dtc and to work on macOS.
#
# Usage: tools/check-dts.sh [kernel-version]
#
set -euo pipefail

KVER="${1:-6.18.44}"
KMAJOR="${KVER%%.*}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Checking board DTS against Linux $KVER"

docker run --rm \
  -v "$REPO_DIR:/repo" \
  -e KVER="$KVER" -e KMAJOR="$KMAJOR" \
  -w /build \
  debian:stable \
  bash /repo/tools/check-dts-inner.sh
