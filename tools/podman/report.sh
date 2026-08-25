#!/usr/bin/env bash
# Summarise a finished build: device utilisation first, then timing.
#   tools/podman/report.sh   -> build/pce/report.txt
#
# The headline number is ALM occupancy on the Pocket's 5CEBA4F23C8, because
# that is what decides whether anything else fits alongside the core. Quartus
# exits 0 on a design that misses timing, so the slack is pulled out here too.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BDIR="$REPO/build/pce"
REV=${REV:-pce_pocket}
OUT="$BDIR/work/projects/output_files"

FIT="$OUT/$REV.fit.summary"
STA="$OUT/$REV.sta.summary"
test -f "$FIT" || { echo "no fitter output in $OUT" >&2; exit 1; }

# "Logic utilization (in ALMs) : 9,876 / 18,480 ( 53 % )" -> used, total, pct,
# free. Quartus rounds its own percentage to a whole number; recompute it.
alm() {
  sed -n 's/^Logic utilization (in ALMs)[^:]*: *//p' "$FIT" | head -1 | tr -d ',' | awk '
    { used = $1; total = $3 }
    END {
      if (!total) { print "ALMs: unavailable"; exit }
      printf "ALMs:      %s / %s  (%.1f%% used, %s free)\n", used, total, 100 * used / total, total - used
    }'
}

worst() {  # worst slack for one analysis type across all corners
  awk -v want="$1" '
    /^Type/ { t = $0 }
    /^Slack/ {
      split(t, a, " Model ");
      n = index(a[2], " '"'"'");
      typ = substr(a[2], 1, n - 1);
      if (typ == want && (!seen || $3 + 0 < min)) { seen = 1; min = $3 + 0; line = t }
    }
    END { if (seen) printf "%-22s %8.3f ns   %s\n", want, min, substr(line, 9); else printf "%-22s   (none)\n", want }
  ' "$STA"
}

{
  echo "revision:  $REV"
  echo "device:    $(sed -n 's/^Device *: *//p' "$FIT" | head -1)"
  echo "commit:    ${GIT_SHA:-unknown}${GIT_DIRTY:+ (dirty)}"
  echo "quartus:   $(cat "$BDIR/quartus.version" 2>/dev/null || echo unknown)"
  echo "elapsed:   $(cat "$BDIR/elapsed" 2>/dev/null || echo '?') s"
  echo
  echo "---- utilization ----"
  alm
  grep -E "Total registers|Total block memory bits|Total RAM Blocks|Total PLLs|Total DSP|Total pins" "$FIT" || true
  if [[ -f "$STA" ]]; then
    echo
    echo "---- worst slack per analysis type (all corners) ----"
    for t in Setup Hold Recovery Removal "Minimum Pulse Width"; do worst "$t"; done
  fi
  echo
  echo "---- fit.summary ----"
  cat "$FIT"
  if [[ -f "$STA" ]]; then
    echo
    echo "---- sta.summary ----"
    cat "$STA"
  fi
} > "$BDIR/report.txt"

sed -n '/^---- utilization/,/^---- worst slack/{/^----/d;p}' "$BDIR/report.txt"
echo "full report: $BDIR/report.txt"

# Timing is reported, not enforced: this harness exists to measure the stock
# core, and a baseline that misses timing is a result, not a build failure.
# STRICT_TIMING=1 turns it into one for builds meant to be flashed.
[[ -f "$STA" ]] || exit 0
rm -f "$BDIR/TIMING_FAILED"
worst_slack=$(awk '/^Slack/ {if (!seen || $3 + 0 < m) {seen = 1; m = $3 + 0}} END {printf "%.3f", m}' "$STA")
if awk -v v="$worst_slack" 'BEGIN {exit !(v < 0)}'; then
  echo
  echo "TIMING FAILED: worst slack ${worst_slack} ns. Not fit to flash."
  echo "  see $BDIR/report.txt; SEED=<n> re-runs the fitter with another placement"
  touch "$BDIR/TIMING_FAILED"
  [[ -n "${STRICT_TIMING:-}" ]] && exit 3
  exit 0
fi
echo "timing met: worst slack ${worst_slack} ns"
