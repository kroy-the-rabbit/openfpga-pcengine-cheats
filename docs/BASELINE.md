# Stock core resource baseline

What the unmodified upstream core costs on the Pocket, so that any later change
can be measured against it rather than guessed at.

    upstream:  agg23/openfpga-pcengine master @ 8810ed6
    device:    Cyclone V 5CEBA4F23C8 (Analogue Pocket)
    quartus:   25.1std.0 Build 1129 Lite Edition, containerised
    settings:  projects/pce_pocket.qsf as checked in (AUTO FIT, SEED 1);
               only NUM_PARALLEL_PROCESSORS changed, which affects compile
               time and nothing else
    reproduce: make pce        (about 19 min on this machine)

## Utilisation

| Resource          |      Used |     Total |    Used | Free  |
| ----------------- | --------: | --------: | ------: | ----: |
| ALMs              |    14,779 |    18,480 | **80.0%** | 3,701 |
| Block memory bits | 1,788,320 | 3,153,920 |   56.7% | 1,365,600 |
| RAM blocks (M10K) |       225 |       308 |   73.1% |    83 |
| DSP blocks        |        17 |        66 |   25.8% |    49 |
| PLLs              |         1 |         4 |   25.0% |     3 |
| Registers         |    14,735 |         - |       - |     - |
| Pins              |       224 |       224 |    100% |     0 |

## Timing

Meets in every corner. Worst slack per analysis type, across all corners:

| Type                | Worst slack | Corner                |
| ------------------- | ----------: | --------------------- |
| Setup               |    2.208 ns | Slow 1100mV 0C        |
| Hold                |    0.103 ns | Fast 1100mV 0C        |
| Recovery            |   38.869 ns | Slow 1100mV 85C       |
| Removal             |    0.424 ns | Fast 1100mV 0C        |
| Minimum Pulse Width |    0.831 ns | Slow 1100mV 85C       |

Every worst path is inside `mf_pllbase`'s own output counters, not in core
logic. The 0.103 ns hold figure is the one to watch: it is small enough that
placement variance alone can move it, so a change that leaves it near zero
should be re-run with another `SEED` before it is believed either way.

## Reading these numbers

ALMs at 80% is the binding constraint, and it is tighter than the raw 3,701
free ALMs suggest. Fitter effort here is `AUTO FIT`, which stops optimising
once timing looks achievable; as occupancy climbs the fitter has less room to
place for speed, so the last few percent of a Cyclone V typically cost slack
rather than fitting cleanly and then failing outright.

RAM blocks at 73% are worth watching separately from the bit count. Only 57% of
the memory *bits* are used but 73% of the M10K *blocks* are claimed, so the
design is already spending blocks on memories too narrow or too shallow to fill
one. Anything new that wants block RAM competes for the 83 remaining blocks,
not for the 1.37 Mbit that looks free.

Pins are at 100% by construction: that is the APF interface, not a limit this
core is pressing against.

## Caveats

* Upstream's own releases are built with Quartus 21.1.1 Lite (the qsf's
  `LAST_QUARTUS_VERSION`). This baseline is 25.1std, so the ALM count is not
  expected to match agg23's release builds exactly. It is the right baseline
  for comparing against anything else built by this harness, which is what it
  is for.
* The qsf sets `ENABLE_SIGNALTAP ON` and names `stp1.stp`, which does not exist
  next to the project. Quartus 25.1 instantiates nothing and does not warn, so
  these figures are the core's own logic with no instrumentation in them.
  `make pce NO_SIGNALTAP=1` removes the assignments if that ever changes.

---

## Fork comparison: vanfanel vs agg23

Measured 2026-08-25 with the same Quartus, settings and machine, via
`make compare A=pce B=vanfanel`. `vanfanel/master` is 19 commits ahead of
`agg23/master` and 0 behind, carrying MiSTer accuracy fixes dated 2025-03-05
through 2026-07-09.

| | agg23 `8810ed6` | vanfanel `b29af7f` | delta |
| --- | ---: | ---: | ---: |
| ALMs | 14,779 (80.0%) | 14,700 (79.5%) | **-79** |
| Registers | 14,735 | 14,720 | -15 |
| Block memory bits | 1,788,320 | 1,788,320 | 0 |
| M10K blocks | 225 (73.1%) | 225 (73.1%) | 0 |
| DSP blocks | 17 | 17 | 0 |
| Setup slack | +2.208 ns | +2.253 ns | +0.045 ns |
| Worst slack (hold) | +0.103 ns | +0.118 ns | **+0.015 ns** |

Twenty months of upstream accuracy work for slightly fewer ALMs and slightly
more timing margin. Only three of vanfanel's seven changed files reach this
build at all: `huc6270.vhd`, `huc6260.vhd` and `pce_top.vhd`. The CD and XE-1AP
changes are in modules Quartus never synthesises here, and the `main.sv` delta
is entirely inside commented-out CD blocks.

One unexplained observation: vanfanel's fit took 2,652 s against the baseline's
1,136 s, on the same machine with the same settings. The result is smaller and
faster, so this is not a design that got harder to place; repeated runs would
say whether it is fitter variance or contention. It is recorded here because it
briefly looked like evidence of a problem and was not.
