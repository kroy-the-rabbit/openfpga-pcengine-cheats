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
