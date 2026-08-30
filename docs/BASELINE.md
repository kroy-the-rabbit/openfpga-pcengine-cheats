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

---

## SuperGrafx removed: the working configuration

Branch `cheats` (`SGX_EN = 0`, commit `85f58ba`) against the vanfanel control,
measured 2026-08-25 via `make compare A=vanfanel B=cheats`.

| | vanfanel | cheats (no SGX) | delta |
| --- | ---: | ---: | ---: |
| ALMs | 14,700 (79.5%) | **9,204 (49.8%)** | -5,496 |
| Registers | 14,720 | 10,096 | -4,624 |
| Block memory bits | 1,788,320 (56.7%) | 1,054,224 (33.4%) | -734,096 |
| M10K blocks | 225 (73.1%) | **134 (43.5%)** | -91 |
| Setup slack | +2.253 ns | +1.831 ns | -0.422 ns |
| Worst slack (hold) | +0.118 ns | +0.122 ns | +0.004 ns |

9,276 ALMs and 174 M10K blocks free, timing met in every corner.

### The block RAM saving came in larger than predicted, and why

The projection was 68 M10Ks: `VDC1`'s 4 plus `VRAM1`'s 64. The measurement is
91. The extra 23 are the work RAM shrinking on its own:

| Entity | vanfanel | cheats |
| --- | ---: | ---: |
| `dpram:RAM` | 32 M10K, 262,144 bits | **8 M10K, 65,536 bits** |

`pce_top.vhd:625` declares work RAM as `dpram (15,8)`, 32KB, because SuperGrafx
needs it. With `SGX = '0'`, `pce_top.vhd:639` ties `RAM_A(14 downto 13)` to
`"00"`, so the top two address bits are constant and Quartus infers an 8KB
memory without being asked. **The manual narrowing to `(13,8)` that the plan
held in reserve is unnecessary.**

One counter-movement worth noting: `HUC6270:VDC0` grew from 5,357 to 5,606 ALMs
(+249) as the only remaining VDC. It is dwarfed by what came out, but it is a
reminder that removing one of two identical instances does not simply halve the
pair.

### Headroom for the cheat work

The GB/GBC cheat stack, overlay included, measured 1,655 ALMs in its own
project. Landing that here would put this core near 10,900 ALMs, about 59%,
with roughly 150 M10K blocks still free. That is the comfortable position the
whole SuperGrafx trade was for: pocket-gbc hit 91% block RAM doing this same
work and had to fight for it.

---

## The PLL hold path, and why builds need watching

One path decides whether a build is flashable, and it is not in core logic:

    Hold  ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk

Its history across every build so far, same Quartus, same machine:

| Build | Change | Hold slack |
| --- | --- | ---: |
| `pce` | agg23 stock | +0.103 ns |
| `vanfanel` | + 20 months of VDC fixes | +0.118 ns |
| `cheats` | + SGX removed | +0.122 ns |
| `swapbits` | + a 16-bit mux on ROM download | **-0.025 ns** |
| `swapbits-s2` | identical RTL, `SEED=2` | +0.103 ns |
| `swapbits-std` | identical RTL, seed 1, **`STANDARD FIT`** | **+0.109 ns** |

The last two rows are the point. **Identical source, 0.128 ns apart, one
failing and one passing.** So the -0.025 ns was placement, not the mux: a
16-bit mux on the SDRAM write path during ROM download is in a different clock
domain from a PLL output counter and cannot plausibly move it.

### Why it swings

The fitter says so itself:

    Fitter Effort : Auto Fit
    Info (171003): Fitter is performing an Auto Fit compilation, which may
                   decrease Fitter effort to reduce compilation time
    Info (16304):  default for this mode is Standard Fit

`AUTO FIT` lowers effort as soon as it believes timing is achievable. On a path
whose margin is around a tenth of a nanosecond, that judgement is worth
overriding.

The controlled comparison is the first and last rows of the table: **same RTL,
same seed, only the effort setting differs, and the build goes from -0.025 ns
to +0.109 ns.** It was also *faster*, 957 s against 1,236 s, so AUTO FIT was
not even buying compile time here.

So `FITTER_EFFORT="STANDARD FIT"` is now the harness default, with
`OPTIMIZE_HOLD_TIMING "ALL PATHS"` alongside it. Both are applied to the build
copy only, so the checked-in project file stays as upstream wrote it, and
`make pce FITTER_EFFORT=` builds the way upstream does.

**What this does not do** is make the path safe. An earlier version of this
section claimed STANDARD FIT "stops the fitter giving up early and landing
negative". That was wrong, and later builds disproved it: `p2` landed at
-0.011 ns and `fix` at -0.013 ns, both under STANDARD FIT at the default seed.

What STANDARD FIT actually does is make a negative landing less frequent, not
impossible. The full STANDARD FIT record is +0.109, +0.093, -0.011, +0.109,
-0.013: two failures in five. The margin still sits in the same 0.09-0.12 ns
band when it passes.

So the rule is not "use STANDARD FIT and trust it". It is **check report.txt
every build, and re-fit at another SEED when it lands negative**. A negative
landing is not evidence the change caused it; `osd` added 345 ALMs on the video
path and moved the slack *up* 0.120 ns against `p2`, which is not how a real
hold regression behaves.

### One fix that does *not* apply here

pocket-gbc solved a similar marginal hold path by declaring its audio PLL's two
outputs asynchronous to each other, because that core's SDC left them in no
clock group at all. **Do not copy that here.** `target/pocket/core_constraints.sdc`
already puts all three `mf_pllbase` outputs in a single `-group`, which is
correct: they are ratio-related outputs of one VCO (42.95 MHz, 85.91 MHz and a
video clock) and the design genuinely relies on synchronous crossings between
them, as the `set_multicycle_path` lines just below it show. Splitting them
into separate groups would false-path real paths and produce a build that
passes timing analysis and fails on hardware.

### Practical rule

Read `report.txt`, not the exit code. Quartus exits 0 on a design that misses
timing; `tools/podman/report.sh` is what catches it and leaves a
`TIMING_FAILED` marker. A build that lands near zero is not evidence that the
change caused it. Re-fit with another `SEED` first, and treat a change as
guilty only if it fails across seeds.

---

## P1: the cheat poker

`make pce BUILD_NAME=poker`, STANDARD FIT, seed 1. Delta against `swapbits-std`,
which is the same tree without the poker:

| | swapbits-std | poker | delta |
| --- | ---: | ---: | ---: |
| ALMs | 9,209 (49.8%) | 9,238 (50.0%) | **+29** |
| Registers | 10,097 | 10,086 | -11 |
| Block memory bits | 1,054,224 | 1,054,242 | +18 |
| M10K blocks | 134 (43.5%) | 135 (43.8%) | **+1** |
| Worst slack (hold) | +0.109 ns | **+0.093 ns** | -0.016 ns |
| Setup | +2.253 ns | +2.393 ns | +0.140 ns |

`cheat_poker` itself is **11 ALMs**, 21 combinational ALUTs and 15 registers.
The other 18 ALMs are the port B mux in `pce_top`, the `0x404` bridge register
and the widened settings synchroniser. Timing met on every analysis type.

Two things worth recording, because both were predicted wrong first.

**The work RAM shrink survived.** Muxing port B between the cold-reset clear and
the poker could have made the upper 24KB of that 32KB block look reachable and
cost back the 24 M10Ks `SGX_EN = 0` freed. It did not: the fit log still shows
`Synthesized away node ... dpram:RAM ... ram_block1a` 24 times. Carrying only 13
poke address bits is what preserves it, and that is why `POKE_A` is 13 bits wide
rather than 15.

**The +1 M10K is a stub, not the table.** Quartus infers the code table as a
real memory (`Inferred altsyncram megafunction ... cheat_poker|tbl_rtl_0`)
rather than folding it into constants, but then trims it: with `SEED_EN = 1` and
one seeded code the scan never leaves index 0, so it reports `Removed 4 MSB VCC
or GND address nodes` and 18 block memory bits survive of the 704 a full 32-entry
table needs. It still occupies a whole M10K. P2 will fill the table without
adding another block, so this +1 is the table's entire block cost, paid early.

**Hold at +0.093 ns** is the lowest passing value recorded on this design, just
under the 0.10-0.12 ns band the earlier builds sat in. It is the same
`general[1].gpll ... divclk` path, and it is positive on every corner, so this
is a pass. Whether the poker actually moved it or this is more of the placement
variance documented above is not established by one build; the previous section
is the reason not to assume the former.

---

## P1 verified on hardware, and what the build numbers mean now

`make pce BUILD_NAME=diag`. This is the build that was tested on a Pocket and
found working.

| | swapbits-std | poker | diag |
| --- | ---: | ---: | ---: |
| ALMs | 9,209 (49.8%) | 9,238 (50.0%) | **8,950 (48.4%)** |
| Registers | 10,097 | 10,086 | 10,100 |
| M10K | 134 (43.5%) | 135 (43.8%) | 134 (43.5%) |
| Worst hold | +0.109 ns | +0.093 ns | **+0.103 ns** |

`diag` is 288 ALMs **smaller** than `poker` despite carrying more logic, and
259 smaller than the baseline with no poker at all. That is not logic going
missing. Two things account for it, and both were checked rather than assumed:

1. The code table lost its only writer when the runtime selector replaced the
   compiled-in seed, so it and its surrounding logic went away. That is the
   M10K.
2. The rest is ALM packing variance, spread evenly over modules nobody touched:
   `HUC6270:VDC0` 5,620.9 to 5,375.3, `HUC6280:CPU` 1,665.6 to 1,602.0. Every
   block shrank a little, which is the signature of denser packing rather than
   deletion. `poker` was the loosely packed outlier, not `diag`.

`cheat_poker` itself is 23 ALMs in `diag`, up from 11, the difference being the
selector table and the wipe sweeper.

### The lesson that cost a build

The first hardware test failed and the mechanism was not why. The compiled-in
cheat was a life counter, which a game need not repaint until it changes, so a
working poke had nothing to show for itself. Two changes came out of it and
both are worth keeping:

* **A write-path diagnostic that bypasses everything clever.** `DEBUG_WIPE`
  sweeps work RAM through the same port B path, ignoring the vblank edge, the
  table and the FSM. It answers "does a write reach memory at all" in one
  toggle, which is the question that was actually in doubt.
* **Runtime cheat selection.** Compiling a test cheat in as a parameter meant
  every hypothesis cost a 15 minute build. The `Test Cheat` dropdown makes it a
  menu change.

Neither is a shipping feature; P6 removes both from `interact.json`. The RTL
stays, parameterised off, costing nothing.
