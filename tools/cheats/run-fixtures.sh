#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the parser model over the checked-in fixtures and diffs against what
# each should produce.
#
# Given a directory it also sweeps a whole libretro cheat database and asserts
# every file yields no codes. That is not a quirk of the fixtures: not one file
# in libretro's PC Engine set has an enable=true, so a correct parser emits
# nothing from any of them, and a parser that emits anything is ignoring the
# enable key. That single assertion is what caught the decimal-form bug.
#
#   tools/cheats/run-fixtures.sh
#   tools/cheats/run-fixtures.sh "/path/to/NEC - PC Engine - TurboGrafx 16"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

for cht in "$HERE"/fixtures/*.cht; do
  exp="${cht%.cht}.expected"
  # strip the filename column so a fixture can be renamed without churn
  got=$(perl "$HERE/chtmodel.pl" "$cht" | sed '1s/^.*codes=/codes=/')
  if diff -q <(echo "$got") "$exp" >/dev/null; then
    echo "ok    $(basename "$cht")"
  else
    echo "FAIL  $(basename "$cht")" >&2
    diff <(echo "$got") "$exp" >&2 || true
    fail=1
  fi
done

if [ $# -ge 1 ] && [ -n "$1" ]; then
  db="$1"
  n=0; bad=0
  for cht in "$db"/*.cht; do
    n=$((n+1))
    line=$(perl "$HERE/chtmodel.pl" "$cht" | head -1)
    case "$line" in
      *"codes=0 "*) ;;
      *) echo "FAIL  emits codes from a file with no enable=true: $line" >&2; bad=$((bad+1));;
    esac
  done
  if [ $bad -eq 0 ]; then
    echo "ok    $n database files, none emits a code"
  else
    echo "FAIL  $bad of $n database files emitted codes" >&2
    fail=1
  fi
fi

[ $fail -eq 0 ] && echo "fixtures ok" || exit 1
