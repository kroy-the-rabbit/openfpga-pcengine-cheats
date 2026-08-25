#!/usr/bin/env bash
# Compare the resource and timing cost of two finished builds.
#   tools/podman/compare.sh pce vanfanel
#
# Both arguments are BUILD_NAME values, i.e. directories under build/. The
# point of this is to answer "what did that change cost" without reading two
# fit summaries side by side and doing the subtraction by hand.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REV=${REV:-pce_pocket}

A=${1:?usage: compare.sh <base-build> <new-build>}
B=${2:?usage: compare.sh <base-build> <new-build>}

fit() { echo "$REPO/build/$1/work/projects/output_files/$REV.fit.summary"; }
sta() { echo "$REPO/build/$1/work/projects/output_files/$REV.sta.summary"; }

for n in "$A" "$B"; do
  test -f "$(fit "$n")" || { echo "no fitter output for build '$n'" >&2; exit 1; }
done

# One metric, both builds, with the delta and its sign. Quartus writes these
# with thousands separators, hence the tr.
row() {
  local label=$1 key=$2
  local a b
  a=$(sed -n "s/^$key[^:]*: *//p" "$(fit "$A")" | head -1 | tr -d ',' | awk '{print $1+0}')
  b=$(sed -n "s/^$key[^:]*: *//p" "$(fit "$B")" | head -1 | tr -d ',' | awk '{print $1+0}')
  local total
  total=$(sed -n "s/^$key[^:]*: *//p" "$(fit "$A")" | head -1 | tr -d ',' | awk '{print $3+0}')
  if [[ -n "$total" && "$total" != 0 ]]; then
    awk -v l="$label" -v a="$a" -v b="$b" -v t="$total" \
      'BEGIN {printf "%-20s %9d %6.1f%%   %9d %6.1f%%   %+8d  %+5.1f pp\n", l, a, 100*a/t, b, 100*b/t, b-a, 100*(b-a)/t}'
  else
    awk -v l="$label" -v a="$a" -v b="$b" \
      'BEGIN {printf "%-20s %9d           %9d           %+8d\n", l, a, b, b-a}'
  fi
}

# Worst slack across every corner and every analysis type: the single number
# that says whether a change ate the margin.
worst() { awk '/^Slack/ {if (!seen || $3+0 < m) {seen=1; m=$3+0}} END {printf "%.3f", m}' "$(sta "$1")"; }

printf '%-20s %9s %7s   %9s %7s   %8s  %8s\n' "" "$A" "" "$B" "" "delta" ""
printf '%s\n' "--------------------------------------------------------------------------------------"
row "ALMs"          "Logic utilization (in ALMs)"
row "Registers"     "Total registers"
row "Block mem bits" "Total block memory bits"
row "M10K blocks"   "Total RAM Blocks"
row "DSP blocks"    "Total DSP Blocks"

if [[ -f "$(sta "$A")" && -f "$(sta "$B")" ]]; then
  wa=$(worst "$A"); wb=$(worst "$B")
  printf '%s\n' "--------------------------------------------------------------------------------------"
  awk -v a="$wa" -v b="$wb" \
    'BEGIN {printf "%-20s %9.3f ns        %9.3f ns        %+8.3f ns\n", "worst slack", a, b, b-a}'
fi
