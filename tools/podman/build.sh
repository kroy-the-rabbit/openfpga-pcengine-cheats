#!/usr/bin/env bash
# Containerised Quartus build for the Pocket PC Engine core. Runs on the HOST
# and drives podman itself, so the container only ever needs Quartus.
#
#   tools/podman/build.sh                  full build
#   SKIP_COMPILE=1 tools/podman/build.sh   re-report existing outputs
#   SEED=2 tools/podman/build.sh           re-run the fitter with another seed
#
# Everything lands in build/pce/. The checked-in tree is never written to:
# Quartus runs against a copy under build/pce/work, which is also what lets us
# change fitter settings without touching files shared with upstream.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BDIR="$REPO/build/pce"
WORK="$BDIR/work"

PODMAN=${PODMAN:-podman}
IMAGE=${IMAGE:-localhost/pocket-quartus:25.1std}
REV=${REV:-pce_pocket}

GIT_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo nogit)
GIT_DIRTY=$(git -C "$REPO" status --porcelain 2>/dev/null | grep -q . && echo 1 || true)

echo "== revision=$REV commit=$GIT_SHA${GIT_DIRTY:+ (dirty)} image=$IMAGE"

# ---- 1. Sync the build copy ------------------------------------------------
# Quartus scratch (db/, incremental_db/, output_files/) is deliberately kept
# across runs so incremental compiles work; `make clean` wipes the lot.
mkdir -p "$WORK"
rsync -a --delete \
  --exclude '.git/' --exclude 'build/' \
  --exclude 'output_files/' --exclude 'db/' --exclude 'incremental_db/' \
  "$REPO/" "$WORK/"

QSF="$WORK/projects/$REV.qsf"
test -f "$QSF" || { echo "no $QSF" >&2; exit 1; }

# ---- 2. Patch the build copy ----------------------------------------------
# Upstream pins the compile to 6 processors, which suits a CI runner. Use what
# the host has, or NPROC if two experiments are sharing the machine.
NP=${NPROC:-ALL}
sed -i "s/^set_global_assignment -name NUM_PARALLEL_PROCESSORS .*$/set_global_assignment -name NUM_PARALLEL_PROCESSORS $NP/" "$QSF"
echo "== parallel processors $NP"

# The checked-in qsf turns SignalTap on and names stp1.stp, which does not exist
# next to the project (the only .stp in the tree is target/pocket/stp1.stp, a
# leftover from another core: it names ap_core.sof and SNES signal sets).
# NO_SIGNALTAP=1 takes the instrumentation out entirely so the utilisation
# number is the core's own. Default is upstream's setting, untouched.
if [[ -n "${NO_SIGNALTAP:-}" ]]; then
  sed -i 's/^set_global_assignment -name ENABLE_SIGNALTAP ON$/set_global_assignment -name ENABLE_SIGNALTAP OFF/' "$QSF"
  sed -i '/^set_global_assignment -name USE_SIGNALTAP_FILE/d; /^set_global_assignment -name SIGNALTAP_FILE/d' "$QSF"
  echo "== SignalTap disabled"
fi

# Fitter effort. Upstream leaves this at AUTO FIT, which lowers effort once the
# fitter thinks timing is achievable. STANDARD FIT costs compile time and buys
# placement quality; it also changes the ALM count, so the baseline number
# should come from an unmodified run.
if [[ -n "${FITTER_EFFORT:-}" ]]; then
  printf '\nset_global_assignment -name FITTER_EFFORT "%s"\n' "$FITTER_EFFORT" >> "$QSF"
  echo "== fitter effort $FITTER_EFFORT"
fi

# Optional fitter seed. Upstream keeps SEED 1 in the qsf; SEED= overrides here
# only. Placement variance alone can move both slack and packing.
if [[ -n "${SEED:-}" ]]; then
  printf '\nset_global_assignment -name SEED %s\n' "$SEED" >> "$QSF"
  echo "== fitter seed $SEED"
fi

# ---- 3. Compile ------------------------------------------------------------
if [[ -z "${SKIP_COMPILE:-}" ]]; then
  start=$(date +%s)
  set +e
  $PODMAN run --rm \
    --userns=keep-id --security-opt label=disable \
    -v "$WORK:/work" -w /work/projects -e HOME=/tmp \
    "$IMAGE" quartus_sh --flow compile "$REV" 2>&1 | tee "$BDIR/build.log"
  rc=${PIPESTATUS[0]}
  set -e
  echo "$(( $(date +%s) - start ))" > "$BDIR/elapsed"
  [[ $rc -eq 0 ]] || { echo "quartus failed (rc=$rc), see $BDIR/build.log" >&2; exit "$rc"; }
  $PODMAN run --rm "$IMAGE" quartus_sh --version 2>/dev/null | sed -n 2p > "$BDIR/quartus.version" || true
else
  echo "== SKIP_COMPILE set, reporting existing outputs"
fi

echo
GIT_SHA="$GIT_SHA" GIT_DIRTY="$GIT_DIRTY" REV="$REV" "$HERE/report.sh"
