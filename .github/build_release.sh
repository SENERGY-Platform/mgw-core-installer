#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Builds an installer release archive from this repository (PLAN.md 3, m8-release.md finding 1). The
# release workflow and the VM tests both use it, so the tested archive is the released one:
#
#   .github/build_release.sh <version> <output folder> [<overlay folder>]
#
# - assets/version holds the version
# - assets/checksums: the sha256 of every other file under assets (sha256sum format, paths relative
#   to assets), checked by recovery before it hands over to a version (PLAN.md 14)
# - the archive root: setup.sh, LICENSE, README.md, assets/, and the links restore.sh and
#   uninstall.sh into assets/scripts
# - the name mgw_core_installer_<version>.tar.gz
#
# The files of the overlay folder, if given, are copied over assets before the checksums are made,
# e.g. an options with a broken image for a failing test version; only the tests use it.

set -e
version="$1"
out="$2"
overlay="$3"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -a "$repo/setup.sh" "$repo/LICENSE" "$repo/README.md" "$repo/assets" "$work/"
if [ -n "$overlay" ]
then
  cp -a "$overlay/." "$work/assets/"
fi
echo "$version" > "$work/assets/version"
(cd "$work/assets" && find . -type f ! -path ./checksums | sort | xargs sha256sum > checksums)
ln -s assets/scripts/restore.sh "$work/restore.sh"
ln -s assets/scripts/uninstall.sh "$work/uninstall.sh"
mkdir -p "$out"
tar -czf "$out/mgw_core_installer_$version.tar.gz" -C "$work" .
