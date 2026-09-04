#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks the APF manifests against limits the Pocket enforces at runtime and
# the core cannot report. Every rule here corresponds to a mistake that has
# actually been made in this repo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_DIR="$(cd "$ROOT/pkg/Cores" && ls -d */ | head -1)"; CORE_DIR="${CORE_DIR%/}"
C="$ROOT/pkg/Cores/$CORE_DIR"
fail=0
say() { echo "  $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

for f in core.json data.json interact.json video.json audio.json input.json variants.json; do
  jq -e . "$C/$f" >/dev/null || bad "$f is not valid JSON"
done

# APF allows 16 interact variables. Nested dropdown options are not variables,
# which is worth stating because miscounting them once put this at "4 free"
# when it was 6.
n=$(jq '.interact.variables | length' "$C/interact.json")
[ "$n" -le 16 ] || bad "interact.json has $n variables, APF allows 16"
say "interact variables: $n/16"

dupe=$(jq -r '[.interact.variables[].id] | group_by(.) | map(select(length>1)) | flatten | @csv' "$C/interact.json")
[ -z "$dupe" ] || bad "duplicate interact ids: $dupe"

dupe=$(jq -r '[.interact.variables[].address] | group_by(.) | map(select(length>1)) | flatten | unique | @csv' "$C/interact.json")
[ -z "$dupe" ] || bad "two interact variables share an address: $dupe"

# The Pocket resolves a core by its directory name, and that name has to be
# exactly "<author>.<shortname>" from core.json. Renaming the directory to
# kroy.PCE while shortname still read "PC Engine" produced a core the Pocket
# listed and then refused to start with "error in core setup". It cost two
# releases to find, because the bitstream and every other manifest were fine
# and the failure looked nothing like a naming problem.
AUTHOR="$(jq -r '.core.metadata.author' "$C/core.json")"
SHORT="$(jq -r '.core.metadata.shortname' "$C/core.json")"
if [ "$CORE_DIR" = "$AUTHOR.$SHORT" ]; then
  say "author.shortname: $AUTHOR.$SHORT"
else
  bad "core directory \"$CORE_DIR\" is not \"$AUTHOR.$SHORT\", which core.json metadata requires"
fi

# The picker app keys on the core directory name and on the release asset
# prefix derived from it, and it has no space in either. Upstream ships as
# "agg23.PC Engine"; this fork is kroy.PCE to match kroy.GBC, kroy.GB and
# kroy.GBA, and so nothing downstream has to quote a space.
case "$CORE_DIR" in
  *" "*) bad "core directory \"$CORE_DIR\" contains a space" ;;
  kroy.*) say "core directory: $CORE_DIR" ;;
  *) bad "core directory \"$CORE_DIR\" is not a kroy.* fork name" ;;
esac

# The bitstream is named by the manifest, not by convention: this core calls it
# pce.rev where the sibling forks use bitstream.rbf_r, and packaging it under
# the wrong name produces a core the Pocket lists and cannot start.
bit=$(jq -r '.core.cores[0].filename' "$C/core.json")
[ -n "$bit" ] && [ "$bit" != "null" ] || bad "core.json names no bitstream"
say "bitstream name: $bit"

# A chip32 program IS the loader when present: APF loads only the slots the
# program names, so declaring a data slot the program never calls loadf on
# delivers nothing. That cost a full debugging cycle; if one is ever added
# back, every slot has to be in it.
if jq -e '.core.framework.chip32_vm' "$C/core.json" >/dev/null 2>&1; then
  bad "core.json declares a chip32 VM: APF will then load only the slots that program names (see docs/CHEATS.md)"
fi

dupe=$(jq -r '[.data.data_slots[].id] | group_by(.) | map(select(length>1)) | flatten | @csv' "$C/data.json")
[ -z "$dupe" ] || bad "duplicate data slot ids: $dupe"

# APF clones a nonvolatile filename only from the first manifest entry. Keep
# the HuCard in that primary position and its automatic Save immediately after
# it. CD mode explicitly rebinds Save from the later cue path in RTL. The save
# size datatable address in core_top.v is coupled to this array index. Save is
# hidden in the menu, so 0,1,100,2 presents Cartridge, Disc, then Cheats.
primary_menu_order=$(jq -r '[.data.data_slots[0:4][].id] | join(",")' "$C/data.json")
[ "$primary_menu_order" = "0,1,100,2" ] || bad "first data slots must be 0,1,100,2 for Cartridge, Save, Disc, Cheats"
if ! rg -q 'datatable_addr <= 1 \* 2 \+ 1;' "$ROOT/target/pocket/core_top.v"; then
  bad "core_top.v must publish the save size at data slot index 1"
fi

# Show cheats is release-facing UI. The CD diagnostic block replaces its
# normal header and doubled diagnostics consume the entire cheat list, so both
# troubleshooting settings must be disabled in every package candidate.
if ! rg -q 'localparam CD_DIAG = 0;' "$ROOT/target/pocket/core_top.v"; then
  bad "release core must disable the CD diagnostic overlay"
fi
if ! rg -q 'localparam CD_DIAG_SCALE = 1;' "$ROOT/target/pocket/core_top.v"; then
  bad "release core must use normal Show cheats scale"
fi

# Two slots sharing the upper nibble means two data_loaders answering the same
# bridge writes.
dupe=$(jq -r '[.data.data_slots[].address | .[0:3]] | group_by(.) | map(select(length>1)) | flatten | unique | @csv' "$C/data.json")
[ -z "$dupe" ] || bad "data slots share an address prefix: $dupe"
say "data slots: $(jq -r '[.data.data_slots[] | "\(.id):\(.name)"] | join(" ")' "$C/data.json")"

# Every file the manifests name has to be in the package.
for f in $(jq -r '.core.cores[].filename' "$C/core.json"); do
  case "$f" in *.rev|*.rbf_r) continue;; esac   # built, not committed
  [ -f "$C/$f" ] || bad "core.json names $f, which is not in the package"
done

[ $fail -eq 0 ] && echo "manifests ok" || exit 1
