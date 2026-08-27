#!/usr/bin/env bash
# Assemble a flashable Pocket core from a finished build.
#
# Quartus emits pce_pocket.rbf with the bit order the Cyclone V configuration
# engine wants. The Pocket's loader wants each byte bit-reversed. That reversal
# is the whole of what this does, plus copying the pkg/ tree around it.
#
# The output name is not ours to pick: core.json names the bitstream, and this
# core calls it pce.rev rather than the bitstream.rbf_r the sibling forks use.
# Read it rather than hardcoding it, so a rename cannot quietly produce a
# package the Pocket refuses to load.
#
# Nothing here needs the container: the reversal is a byte transform and the
# rest is file copying.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="${BUILD_NAME:-pce}"
REV="${REV:-pce_pocket}"

RBF="$ROOT/build/$NAME/work/projects/output_files/$REV.rbf"
OUT="$ROOT/build/$NAME/dist"
CORE_DIR="$(cd "$ROOT/pkg/Cores" && ls -d */ | head -1)"
CORE_DIR="${CORE_DIR%/}"
CORE_JSON="$ROOT/pkg/Cores/$CORE_DIR/core.json"

[ -f "$RBF" ] || { echo "no bitstream at $RBF; run 'make pce BUILD_NAME=$NAME' first" >&2; exit 1; }

BITNAME="$(jq -r '.core.cores[0].filename' "$CORE_JSON")"
[ -n "$BITNAME" ] && [ "$BITNAME" != "null" ] || { echo "core.json does not name a bitstream" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$ROOT/pkg/." "$OUT/"
# .gitkeep only exists to keep the empty Assets directory in git; it has no
# business on an SD card or in a release archive.
find "$OUT" -name .gitkeep -delete

# unpack 'b*' reads each byte LSB-first, pack 'B*' writes it MSB-first, so the
# round trip is exactly a per-byte bit reversal. Byte order is unchanged.
perl -e 'binmode STDIN; binmode STDOUT; local $/; my $d = <STDIN>; print pack("B*", unpack("b*", $d));' \
     < "$RBF" > "$OUT/Cores/$CORE_DIR/$BITNAME"

echo "== dist $OUT"
echo "   core      $CORE_DIR"
echo "   bitstream $BITNAME, $(stat -c%s "$OUT/Cores/$CORE_DIR/$BITNAME") bytes (from $REV.rbf, $(stat -c%s "$RBF") bytes)"
echo
echo "   Copy the contents of $OUT onto the Pocket's SD card root."

# Release archive, laid out so it unzips straight onto the SD card root. Named
# after the core and its manifest version, matching the sibling forks.
VERSION="$(jq -r '.core.metadata.version' "$CORE_JSON")"
ZIP="$ROOT/build/$NAME/${CORE_DIR// /_}_${VERSION}.zip"
rm -f "$ZIP"
(cd "$OUT" && zip -qr "$ZIP" .)
echo "   release   $ZIP ($(stat -c%s "$ZIP") bytes)"
