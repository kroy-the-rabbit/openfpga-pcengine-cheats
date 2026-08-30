# Containerised Quartus for the Pocket PC Engine core

The Pocket's FPGA is a Cyclone V `5CEBA4F23C8`, and this project is an
OpenGateware-style tree: the Quartus project lives in `projects/`, sources come
in through `projects/pce_pocket.qip` and `rtl/pce.qip`, and the board pinout,
the pre/post-flow scripts and `target/pocket/core.qip` are pulled in by
`platform/pocket/pocket.tcl`.

Nothing here is installed on the host. Quartus runs in a container image; the
one this harness defaults to is `localhost/pocket-quartus:25.1std`, built for
the sibling Pocket projects on this machine.

    make pce                 build and report
    make pce NO_SIGNALTAP=1  build with the qsf's SignalTap instrumentation removed
    make pce SEED=2          another fitter placement seed
    make pce SKIP_COMPILE=1  re-report existing outputs
    make report              regenerate build/pce/report.txt
    make shell               shell in the container, project at /work/projects
    make clean               remove build/

## Where things go

The checked-in tree is never written to. `build.sh` rsyncs the repo to
`build/pce/work/` and Quartus compiles there, which is also what makes it safe
to change fitter settings for an experiment: `projects/pce_pocket.qsf` in the
repo stays exactly as upstream has it, and the patched copy is the one that
gets compiled. Quartus scratch (`db/`, `incremental_db/`, `output_files/`)
survives an rsync so incremental compiles work; `make clean` wipes all of it.

Outputs:

    build/pce/report.txt   utilisation and slack summary (see below)
    build/pce/build.log    the full Quartus transcript
    build/pce/elapsed      wall-clock seconds of the compile
    build/pce/work/projects/output_files/   Quartus's own reports and bitstream

## The report

`report.sh` leads with ALM occupancy, because on a part this size that is what
decides whether anything can be added to the core. Quartus rounds its own
percentage to a whole number, so the harness recomputes it from the raw counts
and also prints how many ALMs are free.

Timing is reported but not enforced. This harness exists to measure the stock
core, and a baseline that misses timing is a result rather than a build
failure; `STRICT_TIMING=1` makes negative slack exit non-zero for builds that
are actually meant to be flashed. Either way a `build/pce/TIMING_FAILED` marker
is left behind when slack goes negative.

## Two things upstream's qsf does that affect the numbers

* `NUM_PARALLEL_PROCESSORS 6` is pinned in the qsf. The build copy gets `ALL`,
  or `NPROC=<n>` when two experiments are sharing the machine. This changes
  compile time only.
* `ENABLE_SIGNALTAP ON` with `USE_SIGNALTAP_FILE stp1.stp`. There is no
  `stp1.stp` next to the project; the only one in the tree is
  `target/pocket/stp1.stp`, a leftover from another core (it names
  `ap_core.sof` and its signal sets are SNES SDRAM loading). `NO_SIGNALTAP=1`
  takes the assignments out so the utilisation number is unambiguously the
  core's own.
